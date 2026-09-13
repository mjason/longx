defmodule Longx.AI.Search.Tavily do
  @moduledoc """
  Minimal Tavily client: `POST /search`
  (https://docs.tavily.com/documentation/api-reference).
  """

  alias Longx.AI.SearchTarget

  @type result :: %{
          title: String.t(),
          url: String.t(),
          content: String.t(),
          published_date: String.t() | nil
        }
  @type page :: %{url: String.t(), content: String.t()}

  @spec search(SearchTarget.t(), String.t(), keyword) :: {:ok, [result]} | {:error, term}
  def search(%SearchTarget{} = target, query, opts \\ []) do
    body =
      %{query: query, search_depth: "basic", max_results: Keyword.get(opts, :max_results, 5)}
      |> put_unless_nil(:time_range, opts[:time_range])
      |> put_unless_nil(:include_domains, opts[:include_domains])

    case post(target, "/search", body) do
      {:ok, %{"results" => results}} when is_list(results) ->
        {:ok,
         Enum.map(results, fn r ->
           %{
             title: r["title"] || r["url"],
             url: r["url"],
             content: r["content"] || "",
             published_date: r["published_date"]
           }
         end)}

      {:ok, other} ->
        {:error, {:unexpected_body, other}}

      {:error, _} = error ->
        error
    end
  end

  defp post(target, path, body) do
    request =
      Req.new(
        base_url: target.base_url,
        auth: {:bearer, target.api_key},
        json: body,
        retry: false,
        receive_timeout: :timer.seconds(60)
      )

    case Req.post(request, url: path) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:status, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
