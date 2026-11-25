defmodule MysticWeb.Community.ComponentsTest do
  use ExUnit.Case, async: true
  import MysticWeb.CommunityComponents

  test "autolinks: http(s) URLs with a host only, trailing punctuation left out" do
    assert segments("See https://example.com/a?b=1, then (http://grove.test/x).") == [
             {:text, "See "},
             {:link, "https://example.com/a?b=1"},
             {:text, ", then ("},
             {:link, "http://grove.test/x"},
             {:text, ")."}
           ]

    for text <- [
          "javascript:alert(1)",
          "ftp://files.test/x",
          "data:text/html,<b>x</b>",
          "http://"
        ] do
      assert Enum.all?(segments(text), &match?({:text, _}, &1)), text
    end

    assert segments(~s(https://a.test/"onmouseover="x)) == [
             {:link, "https://a.test/"},
             {:text, ~s("onmouseover="x)}
           ]

    assert segments(nil) == []
  end

  test "the banner of the discussion on screen keeps one notice (the latest reply)" do
    notices =
      Enum.reduce(~w(a a a), [], fn slug, acc -> push_notice(acc, slug, "Title #{slug}") end)

    assert notices == [%{slug: "a", title: "Title a"}]
  end
end
