//! MysticLore native simulation engine, with the same models and rounding as the Elixir reference
//! (`MlLearning.Sim.Orbit`, `MlLearning.Sim.Reaction`). Inputs and outputs are fixed-point integers and
//! the orbit integrator uses `+ - * /` and `sqrt` in the same order, so both engines return the same
//! integers. No user code is ever run: the engine only receives bounded numbers.

pub mod json;

use json::Json;

pub const MAX_INPUT: usize = 65_536;

// ---------------------------------------------------------------------------------------------- orbit

const G: f64 = 39.47841760435743;
const SCALE: f64 = 1.0e6;
const COLLISION: f64 = 0.01;
const ESCAPE: f64 = 100.0;

#[derive(Debug, Clone, Copy)]
pub struct OrbitInput {
    pub velocity: i64,
    pub star_mass: i64,
    pub planet_mass: i64,
    pub distance: i64,
    pub dt: i64,
    pub steps: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct OrbitResult {
    pub frames: Vec<[i64; 4]>,
    pub r_min: i64,
    pub r_max: i64,
    pub eccentricity: i64,
    pub revolutions: i64,
    pub period: Option<i64>,
    pub energy: i64,
    pub bound: bool,
    pub collided: bool,
    pub escaped: bool,
    pub steps_run: i64,
}

fn fix(x: f64) -> i64 {
    // f64::round rounds half away from zero, like Elixir's Kernel.round/1
    (x * SCALE).round() as i64
}

fn within(v: i64, lo: i64, hi: i64) -> bool {
    v >= lo && v <= hi
}

pub fn run_orbit(inp: &OrbitInput) -> Result<OrbitResult, String> {
    if !(within(inp.velocity, 0, 20_000_000)
        && within(inp.star_mass, 100_000, 10_000_000)
        && within(inp.planet_mass, 0, 1_000_000)
        && within(inp.distance, 100_000, 10_000_000)
        && within(inp.dt, 100, 20_000)
        && within(inp.steps, 1, 20_000))
    {
        return Err("out_of_bounds".into());
    }

    let m1 = inp.star_mass as f64 / SCALE;
    let m2 = inp.planet_mass as f64 / SCALE;
    let r0 = inp.distance as f64 / SCALE;
    let v0 = inp.velocity as f64 / SCALE;
    let dt = inp.dt as f64 / SCALE;
    let mt = m1 + m2;
    let gm1 = G * m1;
    let gm2 = G * m2;
    let hdt = 0.5 * dt;
    let hdt2 = hdt * dt;

    // star and planet on the x axis, opposite velocities along y: zero total momentum
    let x1_0 = -(r0 * m2 / mt);
    let x2_0 = r0 * m1 / mt;
    let vy1_0 = -(v0 * m2 / mt);
    let vy2_0 = v0 * m1 / mt;

    let dx0 = x2_0 - x1_0;
    let r2_0 = dx0 * dx0;
    let r_0 = r2_0.sqrt();
    let inv0 = 1.0 / (r2_0 * r_0);
    let ax1_0 = gm2 * dx0 * inv0;
    let ax2_0 = -(gm1 * dx0 * inv0);

    let energy = 0.5 * v0 * v0 - G * mt / r0;
    let stride = (inp.steps + 197) / 198;

    let (mut x1, mut y1, mut x2, mut y2) = (x1_0, 0.0_f64, x2_0, 0.0_f64);
    let (mut vx1, mut vy1, mut vx2, mut vy2) = (0.0_f64, vy1_0, 0.0_f64, vy2_0);
    let (mut ax1, mut ay1, mut ax2, mut ay2) = (ax1_0, 0.0_f64, ax2_0, 0.0_f64);
    let mut prev_dy = 0.0_f64;
    let mut r_min = r_0;
    let mut r_max = r_0;
    let mut revolutions = 0_i64;
    let mut period: Option<i64> = None;
    let mut frames = vec![[0, fix(dx0), 0, fix(r_0)]];
    let mut last = 0_i64;
    let mut collided = false;
    let mut escaped = false;

    for i in 1..=inp.steps {
        let nx1 = x1 + vx1 * dt + ax1 * hdt2;
        let ny1 = y1 + vy1 * dt + ay1 * hdt2;
        let nx2 = x2 + vx2 * dt + ax2 * hdt2;
        let ny2 = y2 + vy2 * dt + ay2 * hdt2;
        let dx = nx2 - nx1;
        let dy = ny2 - ny1;
        let r2 = dx * dx + dy * dy;
        let r = r2.sqrt();
        let frame = [i * inp.dt, fix(dx), fix(dy), fix(r)];
        if r < r_min {
            r_min = r;
        }
        if r > r_max {
            r_max = r;
        }
        last = i;

        if r < COLLISION {
            frames.push(frame);
            collided = true;
            break;
        }

        let inv = 1.0 / (r2 * r);
        let nax1 = gm2 * dx * inv;
        let nay1 = gm2 * dy * inv;
        let nax2 = -(gm1 * dx * inv);
        let nay2 = -(gm1 * dy * inv);
        let nvx1 = vx1 + (ax1 + nax1) * hdt;
        let nvy1 = vy1 + (ay1 + nay1) * hdt;
        let nvx2 = vx2 + (ax2 + nax2) * hdt;
        let nvy2 = vy2 + (ay2 + nay2) * hdt;

        // one full turn = the planet crosses the x > 0 half-axis going up
        if prev_dy < 0.0 && dy >= 0.0 && dx > 0.0 {
            revolutions += 1;
            if period.is_none() {
                period = Some(i * inp.dt);
            }
        }

        let out = r > ESCAPE;
        if i % stride == 0 || i == inp.steps || out {
            frames.push(frame);
        }

        x1 = nx1;
        y1 = ny1;
        x2 = nx2;
        y2 = ny2;
        vx1 = nvx1;
        vy1 = nvy1;
        vx2 = nvx2;
        vy2 = nvy2;
        ax1 = nax1;
        ay1 = nay1;
        ax2 = nax2;
        ay2 = nay2;
        prev_dy = dy;

        if out {
            escaped = true;
            break;
        }
    }

    Ok(OrbitResult {
        frames,
        r_min: fix(r_min),
        r_max: fix(r_max),
        eccentricity: fix((r_max - r_min) / (r_max + r_min)),
        revolutions,
        period,
        energy: fix(energy),
        bound: energy < 0.0,
        collided,
        escaped,
        steps_run: last,
    })
}

// ------------------------------------------------------------------------------------------- reaction

#[derive(Debug, Clone)]
pub struct ReactionInput {
    pub coefficients: Vec<i64>,
    pub sides: Vec<i64>,
    pub atoms: Vec<Vec<i64>>,
    pub initial: Vec<i64>,
    pub yield_pct: i64,
    pub steps: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ReactionResult {
    pub frames: Vec<Vec<i64>>,
    pub atoms_left: Vec<i64>,
    pub atoms_right: Vec<i64>,
    pub balanced: bool,
    pub lowest_terms: bool,
    pub drift: Vec<i64>,
    pub theoretical: i64,
    pub formed: i64,
    pub yield_permille: i64,
    pub limiting: i64,
}

fn reaction_valid(inp: &ReactionInput) -> bool {
    let n = inp.coefficients.len();
    let k = inp.atoms.first().map(|a| a.len()).unwrap_or(0);
    (2..=6).contains(&n)
        && (1..=6).contains(&k)
        && inp.coefficients.iter().all(|&c| within(c, 1, 12))
        && inp.sides.len() == n
        && inp.sides.iter().all(|&s| s == -1 || s == 1)
        && inp.sides.contains(&-1)
        && inp.sides.contains(&1)
        && inp.atoms.len() == n
        && inp.atoms.iter().all(|a| a.len() == k && a.iter().all(|&x| within(x, 0, 20)))
        && inp.initial.len() == n
        && inp.initial.iter().all(|&x| within(x, 0, 1_000_000_000))
        && within(inp.yield_pct, 1, 100)
        && within(inp.steps, 1, 100)
}

fn gcd(a: i64, b: i64) -> i64 {
    if b == 0 {
        a.abs()
    } else {
        gcd(b, a % b)
    }
}

pub fn run_reaction(inp: &ReactionInput) -> Result<ReactionResult, String> {
    if !reaction_valid(inp) {
        return Err("out_of_bounds".into());
    }
    let n = inp.coefficients.len();
    let k = inp.atoms[0].len();

    let side_atoms = |side: i64| -> Vec<i64> {
        (0..k)
            .map(|e| (0..n).filter(|&i| inp.sides[i] == side).map(|i| inp.coefficients[i] * inp.atoms[i][e]).sum())
            .collect()
    };
    let max_extent = |amounts: &[i64]| -> i64 {
        (0..n)
            .filter(|&i| inp.sides[i] == -1)
            .map(|i| amounts[i] / inp.coefficients[i])
            .min()
            .unwrap_or(0)
    };
    let frame = |step: i64, amounts: &[i64]| -> Vec<i64> {
        let mut f = Vec::with_capacity(1 + n + k);
        f.push(step);
        f.extend_from_slice(amounts);
        for e in 0..k {
            f.push((0..n).map(|i| amounts[i] * inp.atoms[i][e]).sum());
        }
        f
    };

    let left = side_atoms(-1);
    let right = side_atoms(1);
    let mut amounts = inp.initial.clone();
    let mut frames = vec![frame(0, &amounts)];

    for s in 1..=inp.steps {
        let extent = max_extent(&amounts) * inp.yield_pct / 100;
        for i in 0..n {
            amounts[i] += inp.sides[i] * inp.coefficients[i] * extent;
        }
        frames.push(frame(s, &amounts));
    }

    let first = &frames[0][1 + n..];
    let last = &frames[frames.len() - 1][1 + n..];
    let drift: Vec<i64> = last.iter().zip(first).map(|(a, b)| a - b).collect();
    let product = inp.sides.iter().position(|&s| s == 1).unwrap_or(0);
    let theoretical = inp.coefficients[product] * max_extent(&inp.initial);
    let formed = amounts[product] - inp.initial[product];
    let min0 = max_extent(&inp.initial);
    let limiting = (0..n)
        .position(|i| inp.sides[i] == -1 && inp.initial[i] / inp.coefficients[i] == min0)
        .unwrap_or(0) as i64;

    Ok(ReactionResult {
        frames,
        balanced: left == right,
        atoms_left: left,
        atoms_right: right,
        lowest_terms: inp.coefficients.iter().fold(0, |g, &c| gcd(g, c)) == 1,
        drift,
        theoretical,
        formed,
        yield_permille: if theoretical > 0 { formed * 1000 / theoretical } else { 0 },
        limiting,
    })
}

// ------------------------------------------------------------------------------------ request / reply

fn int(req: &Json, key: &str) -> Result<i64, String> {
    match req.get(key) {
        Some(Json::Int(n)) => Ok(*n),
        _ => Err(format!("{key} must be an integer")),
    }
}

fn ints(value: Option<&Json>, key: &str) -> Result<Vec<i64>, String> {
    match value {
        Some(Json::Arr(items)) if items.len() <= 16 => items
            .iter()
            .map(|v| match v {
                Json::Int(n) => Ok(*n),
                _ => Err(format!("{key} must contain integers")),
            })
            .collect(),
        _ => Err(format!("{key} must be a list of integers")),
    }
}

fn list(values: &[i64]) -> String {
    let items: Vec<String> = values.iter().map(|v| v.to_string()).collect();
    format!("[{}]", items.join(","))
}

/// One request (a JSON line) → one JSON reply, or an error message.
pub fn run_request(input: &str) -> Result<String, String> {
    if input.len() > MAX_INPUT {
        return Err("input too large".into());
    }
    let req = json::parse(input.trim_end())?;
    match req.get("model") {
        Some(Json::Str(m)) if m == "orbit" => {
            let r = run_orbit(&OrbitInput {
                velocity: int(&req, "velocity")?,
                star_mass: int(&req, "star_mass")?,
                planet_mass: int(&req, "planet_mass")?,
                distance: int(&req, "distance")?,
                dt: int(&req, "dt")?,
                steps: int(&req, "steps")?,
            })?;
            let frames: Vec<String> = r.frames.iter().map(|f| list(f)).collect();
            Ok(format!(
                concat!(
                    "{{\"frames\":[{}],\"metrics\":{{\"r_min\":{},\"r_max\":{},\"eccentricity\":{},",
                    "\"revolutions\":{},\"period\":{},\"energy\":{},\"bound\":{},\"collided\":{},",
                    "\"escaped\":{},\"steps_run\":{}}}}}"
                ),
                frames.join(","),
                r.r_min,
                r.r_max,
                r.eccentricity,
                r.revolutions,
                r.period.map(|p| p.to_string()).unwrap_or_else(|| "null".into()),
                r.energy,
                r.bound,
                r.collided,
                r.escaped,
                r.steps_run
            ))
        }
        Some(Json::Str(m)) if m == "reaction" => {
            let atoms = match req.get("atoms") {
                Some(Json::Arr(rows)) if rows.len() <= 16 => {
                    rows.iter().map(|row| ints(Some(row), "atoms")).collect::<Result<Vec<_>, _>>()?
                }
                _ => return Err("atoms must be a matrix of integers".into()),
            };
            let r = run_reaction(&ReactionInput {
                coefficients: ints(req.get("coefficients"), "coefficients")?,
                sides: ints(req.get("sides"), "sides")?,
                atoms,
                initial: ints(req.get("initial"), "initial")?,
                yield_pct: int(&req, "yield_pct")?,
                steps: int(&req, "steps")?,
            })?;
            let frames: Vec<String> = r.frames.iter().map(|f| list(f)).collect();
            Ok(format!(
                concat!(
                    "{{\"frames\":[{}],\"metrics\":{{\"atoms_left\":{},\"atoms_right\":{},\"balanced\":{},",
                    "\"lowest_terms\":{},\"drift\":{},\"theoretical\":{},\"formed\":{},",
                    "\"yield_permille\":{},\"limiting\":{}}}}}"
                ),
                frames.join(","),
                list(&r.atoms_left),
                list(&r.atoms_right),
                r.balanced,
                r.lowest_terms,
                list(&r.drift),
                r.theoretical,
                r.formed,
                r.yield_permille,
                r.limiting
            ))
        }
        _ => Err("unknown model".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn orbit(velocity: i64, steps: i64) -> OrbitInput {
        OrbitInput { velocity, star_mass: 1_000_000, planet_mass: 1_000, distance: 1_000_000, dt: 2_000, steps }
    }

    #[test]
    fn orbit_is_deterministic_and_sampled_to_at_most_200_frames() {
        let a = run_orbit(&orbit(6_300_000, 20_000)).unwrap();
        let b = run_orbit(&orbit(6_300_000, 20_000)).unwrap();
        assert_eq!(a, b);
        assert!(a.frames.len() <= 200);
        assert_eq!(a.frames[0][0], 0);
        assert_eq!(a.frames.last().unwrap()[0], 20_000 * 2_000);
        for steps in [1, 197, 198, 199, 396, 397, 1000, 19_999] {
            let r = run_orbit(&orbit(6_300_000, steps)).unwrap();
            assert!(r.frames.len() <= 200, "{steps} steps: {} frames", r.frames.len());
        }
    }

    #[test]
    fn orbit_matches_the_elixir_reference_values() {
        // MlLearning.Sim.Orbit with the same input (see test/learning/sim_native_test.exs)
        let r = run_orbit(&orbit(6_300_000, 1_000)).unwrap();
        assert_eq!((r.eccentricity, r.revolutions, r.period), (4_394, 1, Some(1_008_000)));
        assert_eq!((r.r_min, r.r_max, r.frames.len()), (1_000_000, 1_008_827, 168));
        assert!(r.bound && !r.collided && !r.escaped);
    }

    #[test]
    fn orbit_outcomes_fall_escape_and_bounds() {
        // dropped with no speed and a small step: it falls straight into the star
        let slow = run_orbit(&OrbitInput { dt: 100, ..orbit(0, 5_000) }).unwrap();
        assert!(slow.collided && !slow.escaped && slow.steps_run < 5_000);
        let fast = run_orbit(&OrbitInput { dt: 20_000, ..orbit(15_000_000, 20_000) }).unwrap();
        assert!(fast.escaped && !fast.bound);
        assert!(run_orbit(&orbit(20_000_001, 10)).is_err());
        assert!(run_orbit(&orbit(6_300_000, 20_001)).is_err());
        assert!(run_orbit(&OrbitInput { dt: 99, ..orbit(6_300_000, 10) }).is_err());
    }

    fn water(coefficients: Vec<i64>) -> ReactionInput {
        ReactionInput {
            coefficients,
            sides: vec![-1, -1, 1],
            atoms: vec![vec![2, 0], vec![0, 2], vec![2, 1]],
            initial: vec![10_000_000, 5_000_000, 0],
            yield_pct: 90,
            steps: 6,
        }
    }

    #[test]
    fn reaction_conserves_atoms_only_when_balanced() {
        let ok = run_reaction(&water(vec![2, 1, 2])).unwrap();
        assert!(ok.balanced && ok.lowest_terms);
        assert_eq!(ok.drift, vec![0, 0]);
        assert_eq!((ok.formed, ok.theoretical, ok.yield_permille), (9_999_990, 10_000_000, 999));
        assert_eq!(ok.frames.len(), 7);

        let bad = run_reaction(&water(vec![1, 1, 1])).unwrap();
        assert!(!bad.balanced);
        assert_eq!(bad.drift, vec![0, -4_999_995]);
        assert_eq!(bad.limiting, 1);

        let double = run_reaction(&water(vec![4, 2, 4])).unwrap();
        assert!(double.balanced && !double.lowest_terms);
        assert!(run_reaction(&water(vec![13, 1, 2])).is_err());
    }

    #[test]
    fn requests_and_replies_are_json() {
        let out = run_request(
            r#"{"model":"reaction","coefficients":[2,1,2],"sides":[-1,-1,1],"atoms":[[2,0],[0,2],[2,1]],"initial":[10000000,5000000,0],"yield_pct":90,"steps":1}"#,
        )
        .unwrap();
        assert!(out.starts_with(r#"{"frames":[[0,10000000,5000000,0,20000000,10000000],[1,1000000,500000,9000000,20000000,10000000]],"#));
        assert!(out.contains(r#""balanced":true"#));
        assert!(run_request(r#"{"model":"orbit","velocity":1.5}"#).is_err());
        assert!(run_request(r#"{"model":"exec","cmd":"ls"}"#).is_err());
        assert!(json::parse(&run_request(r#"{"model":"orbit","velocity":6300000,"star_mass":1000000,"planet_mass":1000,"distance":1000000,"dt":2000,"steps":50}"#).unwrap()).is_ok());
    }
}
