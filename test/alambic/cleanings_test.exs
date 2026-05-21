defmodule Alambic.CleaningsTest do
  use Alambic.DataCase, async: true

  alias Alambic.Cleanings
  alias Alambic.Cleanings.Cleaning

  test "get/1 returns nil for unknown item_id" do
    assert Cleanings.get("nope") == nil
  end

  test "save/1 upserts a cleaning row" do
    attrs = %{
      item_id: "abc",
      token_labels: [%{"token" => "hi", "label" => "keep"}],
      source_text: "hi world",
      model_version: "v1"
    }

    {:ok, %Cleaning{item_id: "abc"}} = Cleanings.save(attrs)
    assert %Cleaning{source_text: "hi world"} = Cleanings.get("abc")

    {:ok, _} = Cleanings.save(%{attrs | source_text: "hi mars"})
    assert %Cleaning{source_text: "hi mars"} = Cleanings.get("abc")
  end
end
