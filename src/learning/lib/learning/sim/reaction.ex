defmodule MlLearning.Sim.Reaction do
  @moduledoc """
  Modèle `reaction` : une équation chimique rejouée sur plusieurs passages, en calcul entier.
  """

  @doc "`{:ok, %{\"frames\", \"metrics\"}}` ou `{:error, :out_of_bounds}`."
  def run(input) when is_map(input) do
    if valid?(input), do: {:ok, simulate(input)}, else: {:error, :out_of_bounds}
  end

  def run(_input), do: {:error, :out_of_bounds}

  defp valid?(%{
         "coefficients" => coefs,
         "sides" => sides,
         "atoms" => atoms,
         "initial" => initial,
         "yield_pct" => yield_pct,
         "steps" => steps
       }) do
    n = if is_list(coefs), do: length(coefs), else: 0
    k = if is_list(atoms) and atoms != [] and is_list(hd(atoms)), do: length(hd(atoms)), else: 0

    n in 2..6 and k in 1..6 and ints?(coefs, 1, 12) and is_list(sides) and length(sides) == n and
      Enum.all?(sides, &(&1 in [-1, 1])) and -1 in sides and 1 in sides and
      length(atoms) == n and Enum.all?(atoms, &(is_list(&1) and length(&1) == k)) and
      Enum.all?(atoms, &ints?(&1, 0, 20)) and is_list(initial) and length(initial) == n and
      ints?(initial, 0, 1_000_000_000) and is_integer(yield_pct) and yield_pct in 1..100 and
      is_integer(steps) and steps in 1..100
  end

  defp valid?(_input), do: false

  defp ints?(list, lo, hi), do: Enum.all?(list, &(is_integer(&1) and &1 >= lo and &1 <= hi))

  defp simulate(%{"coefficients" => coefs, "sides" => sides, "atoms" => atoms} = input) do
    species = Enum.zip([coefs, sides, atoms])
    k = length(hd(atoms))

    side_atoms = fn side ->
      for e <- 0..(k - 1), do: Enum.sum(for {c, ^side, a} <- species, do: c * Enum.at(a, e))
    end

    left = side_atoms.(-1)
    right = side_atoms.(1)
    initial = input["initial"]

    {amounts, frames} =
      Enum.reduce(1..input["steps"], {initial, [frame(0, initial, atoms)]}, fn s, {n, acc} ->
        extent = div(max_extent(n, species) * input["yield_pct"], 100)
        n = for {ni, {c, side, _}} <- Enum.zip(n, species), do: ni + side * c * extent
        {n, [frame(s, n, atoms) | acc]}
      end)

    frames = Enum.reverse(frames)
    totals = fn frame -> Enum.drop(frame, 1 + length(initial)) end
    product = Enum.find_index(sides, &(&1 == 1))
    first_product_coef = Enum.at(coefs, product)
    theoretical = first_product_coef * max_extent(initial, species)
    formed = Enum.at(amounts, product) - Enum.at(initial, product)

    %{
      "frames" => frames,
      "metrics" => %{
        "atoms_left" => left,
        "atoms_right" => right,
        "balanced" => left == right,
        "lowest_terms" => Enum.reduce(coefs, 0, &Integer.gcd/2) == 1,
        "drift" => Enum.zip_with(totals.(List.last(frames)), totals.(hd(frames)), &(&1 - &2)),
        "theoretical" => theoretical,
        "formed" => formed,
        "yield_permille" => if(theoretical > 0, do: div(formed * 1000, theoretical), else: 0),
        "limiting" => limiting(initial, species)
      }
    }
  end

  # min(n_i div ν_i) sur les réactifs
  defp max_extent(n, species) do
    n
    |> Enum.zip(species)
    |> Enum.flat_map(fn {ni, {c, side, _}} -> if side == -1, do: [div(ni, c)], else: [] end)
    |> Enum.min()
  end

  # premier réactif (ordre des espèces) qui atteint le minimum
  defp limiting(n, species) do
    min = max_extent(n, species)

    n
    |> Enum.zip(species)
    |> Enum.find_index(fn {ni, {c, side, _}} -> side == -1 and div(ni, c) == min end)
  end

  defp frame(step, n, atoms) do
    k = length(hd(atoms))

    totals =
      for e <- 0..(k - 1),
          do: Enum.sum(Enum.zip_with(n, atoms, fn ni, a -> ni * Enum.at(a, e) end))

    [step | n] ++ totals
  end
end
