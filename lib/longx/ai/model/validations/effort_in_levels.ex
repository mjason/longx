defmodule Longx.AI.Model.Validations.EffortInLevels do
  @moduledoc """
  The reasoning levels a model declares are distinct non-empty words, and
  its default effort — when it declares levels at all — is one of them.
  Without levels the effort stays free text (whatever the model advertises).
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    levels = Ash.Changeset.get_attribute(changeset, :reasoning_levels) || []
    effort = Ash.Changeset.get_attribute(changeset, :reasoning_effort)

    cond do
      Enum.any?(levels, &(not is_binary(&1) or String.trim(&1) == "")) ->
        {:error, field: :reasoning_levels, message: "每一档都要有名字"}

      Enum.uniq(levels) != levels ->
        {:error, field: :reasoning_levels, message: "档位重复"}

      levels != [] and is_binary(effort) and effort not in levels ->
        {:error, field: :reasoning_effort, message: "默认档必须是声明的档位之一（#{Enum.join(levels, " / ")}）"}

      true ->
        :ok
    end
  end
end
