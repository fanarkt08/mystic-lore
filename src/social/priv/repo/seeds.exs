# Seeds de social : amis, conversations, groupe et réglages de démo fictifs, idempotents
# (mix run priv/repo/seeds.exs).
import Ecto.Query
alias MlSocial.{Attachments, Chat, Conversation, Friends, Member, Message, Repo, Settings}

[lea, hugo, ines, sarah, theo, clara] =
  Enum.map(
    ~w(lea_moreau hugo_bernard ines_petit sarah_lefevre theo_garnier clara_dubois),
    &MlShared.Demo.user(&1).id
  )

# Passe par les règles réelles : sans effet si déjà amis (ou si un blocage a été posé depuis).
befriend = fn a, b ->
  with {:ok, %{status: "pending", id: id}} <- Friends.send_request(a, b),
       do: Friends.accept(b, id)
end

befriend.(lea, hugo)
befriend.(lea, ines)
Friends.send_request(sarah, lea)

now = DateTime.utc_now()
ago = fn minutes -> DateTime.add(now, -minutes * 60, :second) end

with {:ok, %{conversation: conversation}} <- Chat.open(lea, hugo),
     false <- Repo.exists?(from m in Message, where: m.conversation_id == ^conversation.id) do
  lines = [
    {hugo, "Léa ! J'ai enfin atteint le chapitre du bosquet.", 190},
    {lea, "Super ! La question sur les boucles t'a posé problème ?", 186},
    {hugo, "Un peu : j'oubliais tout le temps le retrait sous la boucle.", 180},
    {lea, "Suis-la pas à pas, ça vient après quelques essais.", 175},
    {hugo, "Ça marche ! On compare nos notes sur la prochaine leçon ce soir ?", 35}
  ]

  Repo.insert_all(
    Message,
    for {sender, body, minutes} <- lines do
      %{
        id: Ecto.UUID.generate(),
        conversation_id: conversation.id,
        sender_id: sender,
        body: body,
        inserted_at: ago.(minutes)
      }
    end
  )

  # Léa a lu jusqu'à son propre dernier message ; Hugo a tout lu.
  for {user, read_at} <- [{lea, ago.(175)}, {hugo, ago.(35)}] do
    Repo.update_all(
      from(m in Member, where: m.conversation_id == ^conversation.id and m.user_id == ^user),
      set: [last_read_at: read_at]
    )
  end
end

Chat.open(lea, ines)

# Image de démonstration générée localement : ciel nocturne en dégradé, étoiles pseudo-aléatoires (graine fixe),
# encodée en PNG (IDAT zlib) puis validée et nettoyée par le chemin réel des pièces jointes.
demo_png = fn ->
  {width, height} = {240, 160}
  :rand.seed(:exsss, {7, 11, 2026})
  stars = MapSet.new(for _ <- 1..90, do: {:rand.uniform(width) - 1, :rand.uniform(height) - 1})

  rows =
    for y <- 0..(height - 1), into: <<>> do
      pixels =
        for x <- 0..(width - 1), into: <<>> do
          if MapSet.member?(stars, {x, y}),
            do: <<243, 241, 255>>,
            else: <<9 + div(y, 8), 14 + div(y, 6), 32 + div(y * 3, 5) + div(x, 24)>>
        end

      <<0>> <> pixels
    end

  chunk = fn type, data ->
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
  end

  <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <>
    chunk.("IHDR", <<width::32, height::32, 8, 2, 0, 0, 0>>) <>
    chunk.("IDAT", :zlib.compress(rows)) <> chunk.("IEND", "")
end

group_name = "Révisions du soir"

unless Repo.exists?(from c in Conversation, where: c.kind == "group" and c.name == ^group_name) do
  {:ok, file} =
    Attachments.prepare(%{
      "data_base64" => Base.encode64(demo_png.()),
      "filename" => "ciel-du-jardin.png",
      "alt" => "Un ciel de nuit au-dessus du jardin, dessiné par Inès pour le groupe"
    })

  {:ok, _} =
    Repo.transact(fn ->
      group =
        Repo.insert!(%Conversation{
          kind: "group",
          name: group_name,
          owner_id: lea,
          inserted_at: ago.(300)
        })

      # Les arrivées précèdent le message de création, car l'historique d'un groupe commence à l'arrivée.
      read = %{lea => ago.(280), hugo => ago.(55), ines => ago.(282)}

      Repo.insert_all(
        Member,
        for {id, i} <- Enum.with_index([lea, hugo, ines]) do
          %{
            conversation_id: group.id,
            user_id: id,
            joined_at: DateTime.add(ago.(300), i - 3, :microsecond),
            last_read_at: read[id]
          }
        end
      )

      Repo.insert!(%{
        Message.system(group.id, lea, "created", %{"name" => group_name})
        | inserted_at: ago.(300)
      })

      lines = [
        {lea, "Bienvenue dans le groupe ! On partage ici nos notes sur l'Atlas céleste.", 295},
        {hugo, "Bonne idée. Ma planète n'arrête pas de s'échapper dans la simulation d'orbite.",
         290},
        {ines,
         "Essaie une vitesse de départ plus faible. Et voici le ciel que j'ai dessiné pour notre projet de jardin :",
         285},
        {lea, "Il est très beau, Inès ! Je l'ajoute au brouillon du Jardin au clair de lune.",
         281},
        {hugo, "Séance de révision demain à 19 h à l'observatoire ?", 60}
      ]

      for {sender, body, minutes} <- lines do
        message =
          Repo.insert!(%Message{
            conversation_id: group.id,
            sender_id: sender,
            body: body,
            inserted_at: ago.(minutes)
          })

        if minutes == 285,
          do: Repo.insert!(Attachments.row(file, Attachments.store!(file), message.id, sender))
      end

      {:ok, group}
    end)
end

for {user, attrs} <- [
      {ines, %{"show_online" => false, "read_receipts" => false, "lobby_invites" => "nobody"}},
      {sarah, %{"show_online" => false, "group_adds" => "nobody"}},
      {theo, %{"friend_requests" => "friends_of_friends"}},
      {clara, %{"friend_requests" => "nobody"}}
    ] do
  {:ok, _} = Settings.update(user, attrs)
end

IO.puts("social seeds: ok")
