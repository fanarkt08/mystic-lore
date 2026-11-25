defmodule MlLearning.Sim.Orbit do
  @moduledoc """
  Modèle `orbit` : une planète autour d'une étoile, intégrée par Verlet sur des entiers en millionièmes.
  """

  @g 39.47841760435743
  @scale 1.0e6
  @collision 0.01
  @escape 100.0

  @bounds %{
    "velocity" => {0, 20_000_000},
    "star_mass" => {100_000, 10_000_000},
    "planet_mass" => {0, 1_000_000},
    "distance" => {100_000, 10_000_000},
    "dt" => {100, 20_000},
    "steps" => {1, 20_000}
  }

  @doc "Bornes des entrées (entiers, millionièmes) : `%{nom => {min, max}}`."
  def bounds, do: @bounds

  @doc "`{:ok, %{\"frames\", \"metrics\"}}` ou `{:error, :out_of_bounds}`."
  def run(input) when is_map(input) do
    if Enum.all?(@bounds, fn {k, {lo, hi}} -> is_integer(input[k]) and input[k] in lo..hi end),
      do: {:ok, simulate(input)},
      else: {:error, :out_of_bounds}
  end

  def run(_input), do: {:error, :out_of_bounds}

  defp simulate(%{"steps" => steps, "dt" => dt_u} = input) do
    m1 = input["star_mass"] / @scale
    m2 = input["planet_mass"] / @scale
    r0 = input["distance"] / @scale
    v0 = input["velocity"] / @scale
    dt = dt_u / @scale
    mt = m1 + m2
    gm1 = @g * m1
    gm2 = @g * m2
    hdt = 0.5 * dt
    hdt2 = hdt * dt

    # étoile et planète sur l'axe x, vitesses opposées selon y : quantité de mouvement totale nulle
    x1 = -(r0 * m2 / mt)
    x2 = r0 * m1 / mt
    vy1 = -(v0 * m2 / mt)
    vy2 = v0 * m1 / mt

    dx = x2 - x1
    r2 = dx * dx
    r = :math.sqrt(r2)
    inv = 1.0 / (r2 * r)
    ax1 = gm2 * dx * inv
    ax2 = -(gm1 * dx * inv)

    energy = 0.5 * v0 * v0 - @g * mt / r0
    stride = div(steps + 197, 198)

    state = %{
      bodies: {x1, 0.0, x2, 0.0, 0.0, vy1, 0.0, vy2, ax1, 0.0, ax2, 0.0},
      prev_dy: 0.0,
      r_min: r,
      r_max: r,
      revolutions: 0,
      period: nil,
      frames: [[0, fix(dx), 0, fix(r)]],
      last: 0,
      outcome: :running
    }

    consts = %{dt: dt, hdt: hdt, hdt2: hdt2, gm1: gm1, gm2: gm2, dt_u: dt_u, stride: stride}
    final = loop(1, steps, state, consts)

    %{
      "frames" => Enum.reverse(final.frames),
      "metrics" => %{
        "r_min" => fix(final.r_min),
        "r_max" => fix(final.r_max),
        "eccentricity" => fix((final.r_max - final.r_min) / (final.r_max + final.r_min)),
        "revolutions" => final.revolutions,
        "period" => final.period,
        "energy" => fix(energy),
        "bound" => energy < 0.0,
        "collided" => final.outcome == :collided,
        "escaped" => final.outcome == :escaped,
        "steps_run" => final.last
      }
    }
  end

  defp loop(i, steps, state, _c) when i > steps, do: state

  defp loop(i, steps, state, c) do
    {x1, y1, x2, y2, vx1, vy1, vx2, vy2, ax1, ay1, ax2, ay2} = state.bodies
    nx1 = x1 + vx1 * c.dt + ax1 * c.hdt2
    ny1 = y1 + vy1 * c.dt + ay1 * c.hdt2
    nx2 = x2 + vx2 * c.dt + ax2 * c.hdt2
    ny2 = y2 + vy2 * c.dt + ay2 * c.hdt2
    dx = nx2 - nx1
    dy = ny2 - ny1
    r2 = dx * dx + dy * dy
    r = :math.sqrt(r2)
    frame = [i * c.dt_u, fix(dx), fix(dy), fix(r)]
    state = %{state | r_min: min(state.r_min, r), r_max: max(state.r_max, r), last: i}

    if r < @collision do
      %{state | frames: [frame | state.frames], outcome: :collided}
    else
      inv = 1.0 / (r2 * r)
      nax1 = c.gm2 * dx * inv
      nay1 = c.gm2 * dy * inv
      nax2 = -(c.gm1 * dx * inv)
      nay2 = -(c.gm1 * dy * inv)
      nvx1 = vx1 + (ax1 + nax1) * c.hdt
      nvy1 = vy1 + (ay1 + nay1) * c.hdt
      nvx2 = vx2 + (ax2 + nax2) * c.hdt
      nvy2 = vy2 + (ay2 + nay2) * c.hdt

      # un tour complet = la planète recoupe le demi-axe x > 0 en montant
      {revolutions, period} =
        if state.prev_dy < 0.0 and dy >= 0.0 and dx > 0.0,
          do: {state.revolutions + 1, state.period || i * c.dt_u},
          else: {state.revolutions, state.period}

      escaped = r > @escape
      sampled = rem(i, c.stride) == 0 or i == steps or escaped

      state = %{
        state
        | bodies: {nx1, ny1, nx2, ny2, nvx1, nvy1, nvx2, nvy2, nax1, nay1, nax2, nay2},
          prev_dy: dy,
          revolutions: revolutions,
          period: period,
          frames: if(sampled, do: [frame | state.frames], else: state.frames)
      }

      if escaped, do: %{state | outcome: :escaped}, else: loop(i + 1, steps, state, c)
    end
  end

  defp fix(x), do: round(x * @scale)
end
