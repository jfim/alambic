defmodule AlambicWeb.ExtractJSON do
  def show(%{response: r}) do
    %{
      item_id: r.item_id,
      xpath: r.xpath,
      source: r.source,
      model_version: r.model_version,
      confidence: r.confidence
    }
  end
end
