# Seeds de multiplayer : un salon ouvert et un salon privé avec une partie gagnée, fictifs et idempotents
# (mix run priv/repo/seeds.exs).
alias MlMultiplayer.{Lobby, Match, MatchEvent, Member, Message, Repo, Rewards, RuneRelay}

[lea, hugo, ines] = Enum.map(~w(lea_moreau hugo_bernard ines_petit), &MlShared.Demo.user(&1).id)

open_id = "00000000-0000-4000-8000-00000000b001"
finished_id = "00000000-0000-4000-8000-00000000b002"
match_id = "00000000-0000-4000-8000-00000000c001"

now = DateTime.utc_now()
ago = fn minutes -> DateTime.add(now, -minutes * 60) end

member = fn lobby_id, user_id, minutes ->
  %Member{
    lobby_id: lobby_id,
    user_id: user_id,
    status: "active",
    connection: "absent",
    last_seen_at: ago.(minutes),
    joined_at: ago.(minutes)
  }
end

unless Repo.get(Lobby, open_id) do
  Repo.insert!(%Lobby{
    id: open_id,
    host_id: hugo,
    title: "Relais du soir",
    visibility: "open",
    max_players: 4,
    inserted_at: ago.(20)
  })

  Repo.insert!(member.(open_id, hugo, 20))

  Repo.insert!(%Message{
    lobby_id: open_id,
    user_id: hugo,
    body:
      "Bienvenue ! Rejoignez le salon, indiquez que vous êtes prêts et on commence dès qu'on est deux.",
    inserted_at: ago.(19)
  })
end

unless Repo.get(Lobby, finished_id) do
  Repo.insert!(%Lobby{
    id: finished_id,
    host_id: lea,
    title: "Relais entre amies",
    visibility: "private",
    max_players: 2,
    current_match_id: match_id,
    inserted_at: ago.(150)
  })

  Repo.insert!(member.(finished_id, lea, 150))
  Repo.insert!(member.(finished_id, ines, 148))

  # Partie jouée par le moteur réel : une tentative inexacte (secret décalé d'un cran), puis la bonne.
  start = RuneRelay.start_event(20_261_123, [lea, ines])
  state = RuneRelay.init(start)
  [first | rest] = state.secret

  {_state, events} =
    Enum.reduce([rest ++ [first], state.secret], {state, []}, fn guess, {state, events} ->
      {:ok, new} = RuneRelay.decide(state, RuneRelay.current_player(state), {:propose, guess})
      {Enum.reduce(new, state, &RuneRelay.apply_event(&2, &1)), events ++ new}
    end)

  journal = [start | events]

  Repo.insert!(%Match{
    id: match_id,
    lobby_id: finished_id,
    status: "won",
    last_seq: length(journal),
    finished_at: ago.(120),
    inserted_at: ago.(140)
  })

  for {event, seq} <- Enum.with_index(journal, 1) do
    Repo.insert!(%MatchEvent{
      match_id: match_id,
      seq: seq,
      type: event["type"],
      user_id: event["user_id"],
      payload: event["payload"],
      inserted_at: ago.(140 - seq * 5)
    })
  end

  for {user_id, body, minutes} <- [
        {lea, "Je lis mes indices d'abord, ensuite tu partages les tiens.", 139},
        {ines, "Voici les miens. On les met en commun avant de proposer !", 138},
        {lea, "Trouvé au deuxième essai, bravo à nous deux !", 121}
      ] do
    Repo.insert!(%Message{
      lobby_id: finished_id,
      user_id: user_id,
      body: body,
      inserted_at: ago.(minutes)
    })
  end

  Rewards.finalize(match_id)
end

IO.puts("multiplayer seeds: ok")
