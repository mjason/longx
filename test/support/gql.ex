defmodule LongxWeb.Gql do
  @moduledoc """
  The wire tests' call into the GraphQL API, in the shape the RPC tests were
  written in: `rpc(conn, action, params)` with `"fields"` (the selection —
  names, and `%{"parent" => [...]}` for a nested object), `"input"` (the
  arguments, camelCase or snake_case keys) and `"identity"` (a record's id).
  The document is built from the domains' own GraphQL definitions (which
  root field, query or mutation, its kind), posted to `/gql`, and the answer
  comes back as `%{"success" => true, "data" => result}` or `%{"success" =>
  false, "errors" => [%{"message", "fields", "field", "code"}]}` — so a test
  reads the API the way the page's client does, and asserts as before.
  """

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint LongxWeb.Endpoint

  @domains [
    Longx.Projects,
    Longx.AI,
    Longx.System,
    Longx.Chrome,
    Longx.Credentials,
    Longx.Watches
  ]

  def rpc(conn, action, params) do
    {kind, entry} = lookup(to_string(action))
    document = document(kind, entry, params)

    conn
    |> put_req_header("content-type", "application/json")
    |> post("/gql", Jason.encode!(%{"query" => document}))
    |> json_response(200)
    |> normalise(field_name(entry.name))
  end

  @doc "The GraphQL document the test sends (for a failing test to print)."
  def document(action, params) do
    {kind, entry} = lookup(to_string(action))
    document(kind, entry, params)
  end

  defp lookup(name) do
    Enum.find_value(@domains, fn domain ->
      Enum.find_value(queries(domain), &(to_string(&1.name) == name && {:query, &1})) ||
        Enum.find_value(mutations(domain), &(to_string(&1.name) == name && {:mutation, &1}))
    end) || raise "no GraphQL query or mutation named #{name}"
  end

  defp queries(domain), do: AshGraphql.Domain.Info.queries(domain)
  defp mutations(domain), do: AshGraphql.Domain.Info.mutations(domain)

  @schema LongxWeb.GraphqlSchema

  defp document(:query, entry, params) do
    defs = root_args(:query, entry.name)
    args = args(params["input"] || %{}, defs)

    "query { #{field_name(entry.name)}#{args}#{selection(params["fields"], root_type(:query, entry.name))} }"
  end

  defp document(:mutation, %{type: type} = entry, params) do
    input = params["input"] || %{}

    args =
      case type do
        t when t in [:update, :destroy] ->
          id = params["identity"] || input["id"]
          rest = Map.delete(input, "id")

          [{"id", id}] ++ if(rest == %{}, do: [], else: [{"input", {:object, rest}}])

        :action when map_size(input) == 0 ->
          []

        _ ->
          [{"input", {:object, input}}]
      end

    root = root_type(:mutation, entry.name)

    # a create / update / destroy mutation answers `{result, errors}`: the record is read under `result`
    selection =
      if type in [:create, :update, :destroy] do
        result = object(root).fields[:result]
        " { result" <> selection(params["fields"], result.type) <> " }"
      else
        selection(params["fields"], root)
      end

    "mutation { #{field_name(entry.name)}#{args_list(args, root_args(:mutation, entry.name))}#{selection} }"
  end

  defp args(map, _defs) when map_size(map) == 0, do: ""
  defp args(map, defs), do: args_list(Enum.to_list(map), defs)

  defp args_list([], _defs), do: ""

  defp args_list(pairs, defs),
    do:
      "(" <>
        Enum.map_join(pairs, ", ", fn {k, v} -> "#{camel(k)}: #{typed(v, arg_type(defs, k))}" end) <>
        ")"

  # a root field's arguments, from the schema
  defp root_args(kind, identifier) do
    root = Absinthe.Schema.lookup_type(@schema, kind)
    (root.fields[identifier] || raise("no #{kind} field #{identifier} in the schema")).args
  end

  defp arg_type(defs, name) do
    case Enum.find(defs, fn {identifier, _} -> camel(identifier) == camel(name) end) do
      {_, arg} -> arg.type
      nil -> nil
    end
  end

  # a value rendered by the type the schema gives it: a map under an input
  # object type is an object literal, one under a Json scalar a JSON string
  defp typed(nil, _type), do: "null"
  defp typed({:object, map}, type), do: typed(map, type)
  defp typed(value, %Absinthe.Type.NonNull{of_type: t}), do: typed(value, t)

  defp typed(list, %Absinthe.Type.List{of_type: t}) when is_list(list),
    do: "[" <> Enum.map_join(list, ", ", &typed(&1, t)) <> "]"

  defp typed(map, identifier)
       when is_map(map) and is_atom(identifier) and not is_nil(identifier) do
    case Absinthe.Schema.lookup_type(@schema, identifier) do
      %Absinthe.Type.InputObject{fields: fields} ->
        "{" <>
          Enum.map_join(map, ", ", fn {k, v} ->
            field_type =
              Enum.find_value(fields, fn {id, f} -> camel(id) == camel(k) && f.type end)

            "#{camel(k)}: #{typed(v, field_type)}"
          end) <> "}"

      _ ->
        literal(map)
    end
  end

  defp typed(value, _type), do: literal(value)

  # a nested object literal (an input object); an untyped map argument is a
  # Json scalar, which reads a JSON string
  defp literal({:object, map}),
    do: "{" <> Enum.map_join(map, ", ", fn {k, v} -> "#{camel(k)}: #{literal(v)}" end) <> "}"

  defp literal(nil), do: "null"
  defp literal(true), do: "true"
  defp literal(false), do: "false"
  defp literal(n) when is_number(n), do: to_string(n)
  defp literal(a) when is_atom(a), do: Jason.encode!(Atom.to_string(a))
  defp literal(s) when is_binary(s), do: Jason.encode!(s)
  defp literal(list) when is_list(list), do: "[" <> Enum.map_join(list, ", ", &literal/1) <> "]"
  defp literal(map) when is_map(map), do: Jason.encode!(Jason.encode!(map))

  # The selection set. A test names the fields it reads (`"fields"`); a named
  # field of an object type without its own list, or no list at all, selects
  # every field of that type, nested objects too — a bare `browsers` reads the
  # whole row, as the page's generated operations do.
  defp root_type(kind, identifier) do
    root = Absinthe.Schema.lookup_type(@schema, kind)
    field = root.fields[identifier] || raise "no #{kind} field #{identifier} in the schema"
    field.type
  end

  defp selection(fields, type_ref, depth \\ 0) do
    case object(type_ref) do
      nil ->
        ""

      _obj when depth > 4 ->
        ""

      obj ->
        wanted = if(fields in [nil, []], do: Map.keys(obj.fields) |> Enum.sort(), else: fields)
        " { " <> Enum.map_join(wanted, " ", &render_field(&1, obj, depth)) <> " }"
    end
  end

  defp render_field(%{} = map, obj, depth),
    do: Enum.map_join(map, " ", fn {name, sub} -> render_field({name, sub}, obj, depth) end)

  defp render_field({name, sub}, obj, depth) do
    {identifier, field} = field_of(obj, name)
    camel(identifier) <> selection(sub, field.type, depth + 1)
  end

  defp render_field(name, obj, depth), do: render_field({name, nil}, obj, depth)

  defp field_of(obj, name) do
    wanted = camel(name)

    Enum.find(obj.fields, fn {identifier, _} -> camel(identifier) == wanted end) ||
      raise "no field #{name} on #{obj.name} (has #{Enum.map_join(Map.keys(obj.fields), ", ", &camel/1)})"
  end

  defp object(%Absinthe.Type.NonNull{of_type: t}), do: object(t)
  defp object(%Absinthe.Type.List{of_type: t}), do: object(t)

  defp object(identifier) when is_atom(identifier) do
    case Absinthe.Schema.lookup_type(@schema, identifier) do
      %Absinthe.Type.Object{} = obj -> obj
      _ -> nil
    end
  end

  defp field_name(name), do: camel(name)

  defp camel(name), do: name |> to_string() |> Absinthe.Utils.camelize(lower: true)

  defp normalise(%{"errors" => errors} = body, _field) when is_list(errors) and errors != [] do
    %{
      "success" => false,
      # AshGraphql reports an argument's error twice, at the field and at the input path
      "errors" =>
        errors
        |> Enum.uniq_by(&{&1["message"], &1["fields"], &1["code"]})
        |> Enum.map(fn e ->
          # the page's client camelCases them the same way
          fields = Enum.map(e["fields"] || [], &camel/1)

          %{
            "message" => e["message"],
            "short_message" => e["short_message"],
            "code" => e["code"],
            "fields" => fields,
            "field" => List.first(fields)
          }
        end),
      "raw" => body
    }
  end

  defp normalise(%{"data" => data}, field) do
    case data[field] do
      %{"result" => result} = wrapped when map_size(wrapped) == 1 ->
        %{"success" => true, "data" => result}

      value ->
        %{"success" => true, "data" => value}
    end
  end
end
