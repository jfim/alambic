defmodule Alambic.ExtractionsTest do
  use Alambic.DataCase, async: true

  alias Alambic.Extractions
  alias Alambic.Extractions.Extraction

  test "get/1 returns nil for unknown item_id" do
    assert Extractions.get("nope") == nil
  end

  test "save/1 upserts an extraction row" do
    attrs = %{
      item_id: "abc",
      xpath: "/html/body/article",
      html_snapshot: "<html>...</html>",
      model_version: "v1"
    }

    {:ok, %Extraction{item_id: "abc"}} = Extractions.save(attrs)
    assert %Extraction{xpath: "/html/body/article"} = Extractions.get("abc")

    {:ok, _} = Extractions.save(%{attrs | xpath: "/html/body/main"})
    assert %Extraction{xpath: "/html/body/main"} = Extractions.get("abc")
  end
end
