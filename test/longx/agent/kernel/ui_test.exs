defmodule Longx.Agent.Kernel.UITest do
  use ExUnit.Case, async: true
  alias Longx.Agent.Kernel.UI

  test "message citations survive without a hosted search and can be recovered on replay" do
    ui = %{"id" => "message", "type" => "agentMessage", "text" => "😀evidence"}

    annotation = %{
      "type" => "url_citation",
      "url" => "https://example.org",
      "title" => "Evidence",
      "start_index" => 0,
      "end_index" => 8
    }

    input = %{
      "content" => [
        %{"type" => "output_text", "text" => "😀", "annotations" => []},
        %{"type" => "output_text", "text" => "evidence", "annotations" => [annotation]}
      ]
    }

    expected = Map.put(Map.delete(annotation, "type"), "offset", 2)
    assert UI.with_citations(ui, input)["citations"] == [expected]
    assert UI.with_citations(UI.with_citations(ui, input), input)["citations"] == [expected]
    assert UI.with_citations(ui, %{"content" => []}) == ui
    assert UI.with_citations(nil, input) == nil
  end
end
