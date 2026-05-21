defmodule Alambic.HtmlSanitizerTest do
  use ExUnit.Case, async: true

  alias Alambic.HtmlSanitizer

  test "drops script, style, iframe, object, embed, noscript, link" do
    input = """
    <p>keep</p>
    <script>alert(1)</script>
    <style>body{display:none}</style>
    <iframe src="x"></iframe>
    <object data="x"></object>
    <embed src="x" />
    <noscript>foo</noscript>
    <link rel="stylesheet" href="x" />
    """

    out = HtmlSanitizer.sanitize(input, "item-1")
    assert out =~ "<p>keep</p>"
    refute out =~ "alert"
    refute out =~ "<script"
    refute out =~ "<style"
    refute out =~ "<iframe"
    refute out =~ "<object"
    refute out =~ "<embed"
    refute out =~ "<noscript"
    refute out =~ "<link"
  end

  test "strips on* event handler attributes" do
    html = ~s{<a href="/x" onclick="boom()">go</a>}
    out = HtmlSanitizer.sanitize(html, "item-1")
    assert out =~ ~s[href="/x"]
    refute out =~ "onclick"
  end

  test "rewrites img src to the cham-archived asset URL" do
    base_url = "http://cham.test"
    Application.put_env(:alambic, :cham_base_url, base_url)
    url = "https://example.com/photo.jpg"
    md5 = :crypto.hash(:md5, url) |> Base.encode16(case: :lower)

    out =
      HtmlSanitizer.sanitize(
        ~s{<img src="#{url}" srcset="#{url} 2x" alt="a">},
        "item-1"
      )

    assert out =~ ~s|src="http://cham.test/api/v1/items/item-1/files/img_#{md5}.jpg"|
    refute out =~ "srcset"
    assert out =~ ~s[alt="a"]
  end

  test "drops img src when the URL has no usable extension" do
    out = HtmlSanitizer.sanitize(~s{<img src="https://example.com/photo" alt="a">}, "item-1")
    refute out =~ "src="
    assert out =~ ~s[alt="a"]
  end

  test "returns empty string on unparseable input" do
    assert HtmlSanitizer.sanitize(:not_a_string, "item-1") == ""
  end
end
