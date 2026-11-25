defmodule MlLearning.CatalogTest do
  use MlLearning.DataCase, async: true
  alias MlLearning.Catalog

  defp titles(params),
    do: params |> Catalog.list_adventures() |> Map.fetch!(:entries) |> Enum.map(& &1.title)

  test "paginates by 6, sorted by title by default" do
    for i <- 1..8, do: adventure_fixture(title: "Tale #{i}")

    assert %{entries: first, page: 1, total: 8, total_pages: 2} = Catalog.list_adventures(%{})
    assert Enum.map(first, & &1.title) == for(i <- 1..6, do: "Tale #{i}")
    assert %{entries: second, page: 2} = Catalog.list_adventures(%{"page" => "2"})
    assert Enum.map(second, & &1.title) == ["Tale 7", "Tale 8"]
    assert %{entries: [], page: 3, total_pages: 2} = Catalog.list_adventures(%{"page" => "3"})

    for bad <- ["0", "-1", "abc", "1.5", nil],
        do: assert(%{page: 1} = Catalog.list_adventures(%{"page" => bad}))
  end

  test "an empty catalogue still has one page" do
    assert %{entries: [], total: 0, total_pages: 1, page: 1} = Catalog.list_adventures(%{})
  end

  test "filters by category, difficulty and access, combined" do
    adventure_fixture(title: "Loops", category: "coding", difficulty: "beginner")
    adventure_fixture(title: "Stars", category: "science", difficulty: "intermediate")

    adventure_fixture(
      title: "Engines",
      category: "science",
      difficulty: "intermediate",
      premium: true
    )

    assert titles(%{"category" => "science"}) == ["Engines", "Stars"]
    assert titles(%{"difficulty" => "beginner"}) == ["Loops"]
    assert titles(%{"access" => "free"}) == ["Loops", "Stars"]
    assert titles(%{"access" => "premium"}) == ["Engines"]
    assert titles(%{"category" => "science", "access" => "free"}) == ["Stars"]
    assert titles(%{"category" => "unknown"}) == []
    # Valeurs vides ou non textuelles : pas de filtre.
    assert titles(%{"category" => "", "access" => "", "difficulty" => ["x"]}) == [
             "Engines",
             "Loops",
             "Stars"
           ]
  end

  test "searches title and summary case-insensitively, with LIKE wildcards escaped" do
    adventure_fixture(title: "100% Magic", summary: "Full power.")
    adventure_fixture(title: "1000 Magics", summary: "Many spells.")
    adventure_fixture(title: "snake_case runes", summary: "Underscores.")
    adventure_fixture(title: "snakeXcase runes", summary: "No underscore.")
    adventure_fixture(title: "Back\\slash", summary: "One backslash.")
    adventure_fixture(title: "The Quiet Pond", summary: "A WHISPERING pond.")

    assert titles(%{"q" => "100%"}) == ["100% Magic"]
    assert titles(%{"q" => "%"}) == ["100% Magic"]
    assert titles(%{"q" => "snake_case"}) == ["snake_case runes"]
    assert titles(%{"q" => "k\\s"}) == ["Back\\slash"]
    assert titles(%{"q" => "  whispering "}) == ["The Quiet Pond"]
    assert Enum.sort(titles(%{"q" => "magic"})) == ["100% Magic", "1000 Magics"]
    assert length(titles(%{"q" => ""})) == 6
  end

  test "sorts by newest and by shortest" do
    now = DateTime.utc_now(:second)

    adventure_fixture(
      title: "Old",
      duration_minutes: 10,
      inserted_at: DateTime.add(now, -3, :day)
    )

    adventure_fixture(
      title: "Recent",
      duration_minutes: 90,
      inserted_at: DateTime.add(now, -1, :day)
    )

    adventure_fixture(
      title: "Middle",
      duration_minutes: 45,
      inserted_at: DateTime.add(now, -2, :day)
    )

    assert titles(%{"sort" => "newest"}) == ["Recent", "Middle", "Old"]
    assert titles(%{"sort" => "shortest"}) == ["Old", "Middle", "Recent"]
    assert titles(%{"sort" => "bogus"}) == ["Middle", "Old", "Recent"]
  end

  test "fetches an adventure with ordered chapters and lessons, and a lesson with its neighbours" do
    adventure = adventure_fixture(%{}, [[%{title: "A"}, %{title: "B"}], [%{title: "C"}]])
    assert {:ok, fetched} = Catalog.fetch_adventure(adventure.slug)
    assert fetched |> Catalog.lessons() |> Enum.map(& &1.title) == ["A", "B", "C"]
    assert {:error, :not_found} = Catalog.fetch_adventure("nope")

    [a, b, c] = lessons_of(adventure)
    assert Catalog.neighbours(a) == {nil, b.id}
    assert Catalog.neighbours(b) == {a.id, c.id}
    assert Catalog.neighbours(c) == {b.id, nil}

    assert {:error, :not_found} = Catalog.fetch_lesson(Ecto.UUID.generate())
    assert {:error, :not_found} = Catalog.fetch_lesson("not-a-uuid")
    assert {:error, :not_found} = Catalog.fetch_lesson("0123456789abcdef")
  end
end
