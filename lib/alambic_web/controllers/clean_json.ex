defmodule AlambicWeb.CleanJSON do
  def show(%{response: r}) do
    %{
      item_id: r.item_id,
      cleaned_text: r.cleaned_text,
      source: r.source,
      model_version: r.model_version,
      confidence: r.confidence
    }
  end
end
