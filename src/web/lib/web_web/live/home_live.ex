defmodule MysticWeb.HomeLive do
  @moduledoc "Landing page with the adventures, the plans and a static preview of the studio."
  use MysticWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    adventures =
      case Api.get(socket, :learning, "/api/adventures") do
        {:ok, %{"entries" => entries}} -> Enum.take(entries, 3)
        _ -> :unavailable
      end

    plans =
      case Api.get(socket, :billing, "/api/plans") do
        {:ok, %{"plans" => plans} = body} -> %{list: plans, mode: body["mode"]}
        _ -> :unavailable
      end

    {:ok,
     assign(socket,
       page_title: gettext("Learn through adventure"),
       adventures: adventures,
       plans: plans
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      current_path={@current_path}
      bleed
    >
      <div class="landing">
        <section class="landing-hero" aria-labelledby="hero-title">
          <div class="container-wide grid items-center gap-10 py-12 md:py-20 lg:grid-cols-[minmax(0,1.05fr)_minmax(0,1fr)]">
            <div class="space-y-6">
              <h1 id="hero-title" class="text-5xl leading-[1.02] md:text-6xl xl:text-7xl">
                {gettext("Every lesson is a chapter of your adventure.")}
              </h1>
              <p class="max-w-xl text-lg text-muted">
                {gettext(
                  "MysticLore turns learning into a story you live: read the tale, solve the riddle, cast your first loop — and keep going with friends."
                )}
              </p>
              <div class="flex flex-wrap gap-3">
                <%= if @current_user do %>
                  <.button navigate={~p"/dashboard"}>{gettext("Go to my dashboard")}</.button>
                <% else %>
                  <.button href={~p"/register"}>{gettext("Start your adventure")}</.button>
                <% end %>
                <.button navigate={~p"/adventures"} variant="secondary">
                  {gettext("Browse adventures")}
                </.button>
              </div>
            </div>
            <div class="hero-visual">
              <.art cover="hero" class="aspect-[5/4] rounded-panel" loading="eager" />
              <ol class="hero-journal" aria-label={gettext("How a chapter unfolds")}>
                <li><.icon name="hero-book-open" class="size-4" /> {gettext("Read the tale")}</li>
                <li>
                  <.icon name="hero-puzzle-piece" class="size-4" /> {gettext("Solve the riddle")}
                </li>
                <li>
                  <.icon name="hero-code-bracket" class="size-4" /> {gettext("Write the spell")}
                </li>
              </ol>
            </div>
          </div>
        </section>

        <section class="container-wide section" aria-labelledby="academy-title">
          <div class="section-head">
            <p class="eyebrow">{gettext("The academy")}</p>
            <h2 id="academy-title" class="text-4xl md:text-5xl">
              {gettext("A school where knowledge is a quest")}
            </h2>
          </div>
          <div class="grid gap-6 md:grid-cols-3">
            <article :for={{icon, title, text} <- pillars()} class="card space-y-3">
              <span class="feature-icon"><.icon name={icon} /></span>
              <h3 class="text-2xl">{title}</h3>
              <p class="text-muted">{text}</p>
            </article>
          </div>
        </section>

        <section
          id="first-adventures"
          class="container-wide section"
          aria-labelledby="adventures-title"
        >
          <div class="section-head md:flex md:items-end md:justify-between">
            <div class="space-y-2">
              <p class="eyebrow">{gettext("From the catalogue")}</p>
              <h2 id="adventures-title" class="text-4xl md:text-5xl">
                {gettext("Your first adventures")}
              </h2>
            </div>
            <.link navigate={~p"/adventures"} class="link">{gettext("Explore all adventures")} →</.link>
          </div>
          <%= case @adventures do %>
            <% :unavailable -> %>
              <.unavailable id="adventures-unavailable">
                {gettext("Adventures can't be loaded right now.")}
              </.unavailable>
            <% [] -> %>
              <.empty_state icon="hero-map" title={gettext("The first adventures are being written")} />
            <% adventures -> %>
              <div class="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
                <.adventure_card
                  :for={a <- adventures}
                  id={"home-adventure-#{a["slug"]}"}
                  adventure={a}
                />
              </div>
          <% end %>
        </section>

        <section class="container-wide section" aria-labelledby="formats-title">
          <div class="section-head">
            <p class="eyebrow">{gettext("Lesson formats")}</p>
            <h2 id="formats-title" class="text-4xl md:text-5xl">{gettext("Three ways to learn")}</h2>
          </div>
          <div class="grid gap-6 md:grid-cols-3">
            <article :for={{kind, text} <- formats()} class="card space-y-3">
              <span class="feature-icon"><.icon name={kind_icon(kind)} /></span>
              <h3 class="text-2xl">{kind_label(kind)}</h3>
              <p class="text-muted">{text}</p>
            </article>
          </div>
        </section>

        <section class="container-wide section" aria-labelledby="path-title">
          <div class="section-head">
            <p class="eyebrow">{gettext("Your path")}</p>
            <h2 id="path-title" class="text-4xl md:text-5xl">
              {gettext("Three steps to your first chapter")}
            </h2>
          </div>
          <ol class="grid gap-6 md:grid-cols-3">
            <li :for={{{title, text}, i} <- Enum.with_index(steps(), 1)} class="card step">
              <span class="step-number" aria-hidden="true">{i}</span>
              <h3 class="text-2xl">
                <span class="sr-only">{gettext("Step %{n}:", n: i)}</span> {title}
              </h3>
              <p class="text-muted">{text}</p>
            </li>
          </ol>
        </section>

        <section class="container-wide section" aria-labelledby="friends-title">
          <div class="panel grid items-center gap-8 lg:grid-cols-2">
            <.art cover="observatory" class="aspect-[16/10] rounded-card" />
            <div class="space-y-4">
              <p class="eyebrow">{gettext("Better together")}</p>
              <h2 id="friends-title" class="text-4xl md:text-5xl">{gettext("Learn with friends")}</h2>
              <p class="text-muted">
                {gettext(
                  "Add classmates as friends, talk in private conversations and keep each other going. You stay in control: only friends can message you, and you can block or report anyone at any time."
                )}
              </p>
              <ul class="space-y-2">
                <li class="flex gap-2">
                  <.icon name="hero-user-plus" class="mt-0.5 text-magic" /> {gettext(
                    "Friend requests you accept or decline"
                  )}
                </li>
                <li class="flex gap-2">
                  <.icon name="hero-chat-bubble-left-right" class="mt-0.5 text-magic" /> {gettext(
                    "Real-time messages between friends"
                  )}
                </li>
                <li class="flex gap-2">
                  <.icon name="hero-shield-check" class="mt-0.5 text-magic" /> {gettext(
                    "Blocking and reporting built in"
                  )}
                </li>
              </ul>
            </div>
          </div>
        </section>

        <section class="container-wide section" aria-labelledby="xp-title">
          <div class="section-head">
            <p class="eyebrow">{gettext("Progress")}</p>
            <h2 id="xp-title" class="text-4xl md:text-5xl">
              {gettext("XP, level badges and streaks")}
            </h2>
          </div>
          <div class="grid gap-6 md:grid-cols-3">
            <article :for={{icon, title, text} <- progress_features()} class="card space-y-3">
              <span class="feature-icon feature-icon-reward"><.icon name={icon} /></span>
              <h3 class="text-2xl">{title}</h3>
              <p class="text-muted">{text}</p>
            </article>
          </div>
        </section>

        <section id="studio-preview" class="container-wide section" aria-labelledby="studio-title">
          <div class="grid items-center gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
            <div class="space-y-4">
              <p class="eyebrow">{gettext("The studio")}</p>
              <h2 id="studio-title" class="text-4xl md:text-5xl">
                {gettext("Write your own adventure")}
              </h2>
              <p class="text-muted">
                {gettext(
                  "Brief, outline, lessons, review, publication: the studio guides members through five steps. AI suggestions are proposals you edit; without an AI key, AI generation is unavailable in production, and a demo generator labelled as such is used elsewhere. Every adventure is reviewed by the staff before it joins the catalogue."
                )}
              </p>
              <.button navigate={~p"/studio"} variant="secondary" id="studio-preview-link">
                <.icon name="hero-pencil-square" /> {gettext("Open the studio")}
              </.button>
            </div>
            <figure class="landing-studio" aria-labelledby="studio-preview-caption">
              <p class="landing-studio-tag">
                <.icon name="hero-photo" class="size-4" /> {gettext("Example — static illustration")}
              </p>
              <ol class="landing-studio-steps" aria-hidden="true">
                <li class="is-done">{gettext("Brief")}</li>
                <li class="is-done">{gettext("Outline")}</li>
                <li class="is-current">{gettext("Build")}</li>
                <li>{gettext("Review")}</li>
                <li>{gettext("Publish")}</li>
              </ol>
              <div class="landing-studio-body" aria-hidden="true">
                <p class="text-xs uppercase tracking-widest text-muted">{gettext("Module 1")}</p>
                <p class="font-display text-2xl text-ink">{gettext("The Lantern of Orbits")}</p>
                <ul class="space-y-2 text-sm">
                  <li class="landing-studio-lesson">
                    <.icon name="hero-book-open" class="size-4" /> {gettext(
                      "Story · Why do planets wander?"
                    )}
                  </li>
                  <li class="landing-studio-lesson">
                    <.icon name="hero-puzzle-piece" class="size-4" /> {gettext(
                      "Quiz · Which force pulls the moon?"
                    )}
                  </li>
                  <li class="landing-studio-lesson">
                    <.icon name="hero-beaker" class="size-4" /> {gettext("Simulation · Launch a moon")}
                  </li>
                </ul>
              </div>
              <figcaption id="studio-preview-caption" class="text-sm text-muted">
                {gettext(
                  "An example of a project in the studio. It is a static picture: nothing here was generated, and no AI is called on this page."
                )}
              </figcaption>
            </figure>
          </div>
        </section>

        <section id="offers" class="container-wide section" aria-labelledby="offers-title">
          <div class="section-head">
            <p class="eyebrow">{gettext("Membership")}</p>
            <h2 id="offers-title" class="text-4xl md:text-5xl">
              {gettext("Start free, upgrade when you want")}
            </h2>
          </div>
          <%= case @plans do %>
            <% :unavailable -> %>
              <.unavailable id="plans-unavailable">
                {gettext("Plans can't be loaded right now.")}
              </.unavailable>
            <% plans -> %>
              <div class="space-y-6">
                <.payment_mode_banner mode={plans.mode} />
                <div class="grid gap-6 md:grid-cols-3">
                  <.plan_card :for={plan <- plans.list} id={"plan-#{plan["key"]}"} plan={plan}>
                    <:action>
                      <.button
                        :if={@current_user}
                        navigate={~p"/membership"}
                        variant={if plan["key"] == "premium", do: "reward", else: "secondary"}
                        class="w-full"
                      >
                        {gettext("See my membership")}
                      </.button>
                      <.button
                        :if={!@current_user}
                        href={~p"/register"}
                        variant={if plan["key"] == "premium", do: "reward", else: "secondary"}
                        class="w-full"
                      >
                        {gettext("Get started")}
                      </.button>
                    </:action>
                  </.plan_card>
                </div>
              </div>
          <% end %>
        </section>

        <section id="faq" class="container-wide section" aria-labelledby="faq-title">
          <div class="grid gap-8 lg:grid-cols-[1fr_2fr]">
            <div class="space-y-2">
              <p class="eyebrow">{gettext("FAQ")}</p>
              <h2 id="faq-title" class="text-4xl md:text-5xl">{gettext("Questions, answered")}</h2>
            </div>
            <div class="space-y-3">
              <details :for={{q, a} <- faq()} class="faq">
                <summary>{q}</summary>
                <p class="text-muted">{a}</p>
              </details>
              <p>
                <.link navigate={~p"/help"} class="help-link" id="faq-more">
                  {gettext("More answers in the help center")} →
                </.link>
              </p>
            </div>
          </div>
        </section>

        <section id="help-links" class="container-wide section" aria-labelledby="help-links-title">
          <div class="grid gap-6 md:grid-cols-3">
            <article class="card space-y-3">
              <span class="feature-icon"><.icon name="hero-lifebuoy" /></span>
              <h2 id="help-links-title" class="text-2xl">{gettext("Help center")}</h2>
              <p class="text-muted">
                {gettext("Account, lessons, membership, messages, personal data: searchable answers.")}
              </p>
              <.link navigate={~p"/help"} class="help-link" id="home-help">{gettext("Find an answer")} →</.link>
            </article>
            <article class="card space-y-3">
              <span class="feature-icon"><.icon name="hero-envelope" /></span>
              <h2 class="text-2xl">{gettext("Contact the team")}</h2>
              <p class="text-muted">
                {gettext("A question or a problem? Write to us; we can't promise a response time.")}
              </p>
              <.link navigate={~p"/contact"} class="help-link" id="home-contact">{gettext(
                "Contact us"
              )} →</.link>
            </article>
            <article class="card space-y-3">
              <span class="feature-icon"><.icon name="hero-document-text" /></span>
              <h2 class="text-2xl">{gettext("Legal information")}</h2>
              <p class="text-muted">
                {gettext("Privacy, terms, cookies and accessibility (provisional texts).")}
              </p>
              <.link navigate={~p"/legal"} class="help-link" id="home-legal">{gettext(
                "Read the documents"
              )} →</.link>
            </article>
          </div>
        </section>

        <section class="container-wide section pb-20" aria-labelledby="cta-title">
          <div class="cta-band">
            <h2 id="cta-title" class="text-4xl md:text-5xl">
              {gettext("Your first chapter is waiting.")}
            </h2>
            <p class="max-w-xl text-muted">
              {gettext("Free adventures are open to every member. No card needed.")}
            </p>
            <.button :if={!@current_user} href={~p"/register"}>{gettext("Create my account")}</.button>
            <.button :if={@current_user} navigate={~p"/adventures"}>{gettext("Pick an adventure")}</.button>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp pillars do
    [
      {"hero-book-open", gettext("Story-first lessons"),
       gettext("Each idea arrives inside a scene, so you remember why it matters.")},
      {"hero-chat-bubble-bottom-center-text", gettext("Practice that answers back"),
       gettext("Quizzes and coding spells give immediate, specific feedback.")},
      {"hero-trophy", gettext("Progress that feels earned"),
       gettext("XP, levels and streaks reflect lessons you actually completed.")}
    ]
  end

  defp formats do
    [
      {"story", gettext("Read a short scene that introduces the idea, then mark it complete.")},
      {"exercise", gettext("Answer a riddle: the feedback explains why, right or wrong.")},
      {"coding",
       gettext(
         "Write a tiny, safely bounded spell — like a loop that waters the grove — and run it."
       )}
    ]
  end

  defp steps do
    [
      {gettext("Create your account"), gettext("Sign up, then confirm your email address.")},
      {gettext("Choose an adventure"),
       gettext("Filter by subject, difficulty or length. Free adventures are open to everyone.")},
      {gettext("Learn and level up"),
       gettext("Complete lessons to earn XP, grow your level and keep your streak alive.")}
    ]
  end

  defp progress_features do
    [
      {"hero-bolt", gettext("XP for real progress"),
       gettext(
         "Each lesson grants its XP once. Replaying is welcome, it just never inflates your total."
       )},
      {"hero-star", gettext("Level badges"),
       gettext(
         "Your level badge grows as your XP adds up — it's the first thing on your dashboard."
       )},
      {"hero-fire", gettext("Streaks"),
       gettext("Learn on consecutive days to keep your streak burning.")}
    ]
  end

  defp faq do
    [
      {gettext("Is MysticLore real?"),
       gettext("It's a demonstration project: adventures, members and payments are fictional.")},
      {gettext("Do I have to pay?"),
       gettext(
         "No. Free adventures are open to every member. Premium adventures need a paid plan; in demo payment mode the payment is simulated and no money moves."
       )},
      {gettext("How is XP counted?"),
       gettext(
         "Each lesson awards its XP once, the first time you complete it. Your dashboard shows your level, your streak and your last 7 days."
       )},
      {gettext("Who can message me?"),
       gettext(
         "Only your friends. Conversations are private between you two, but they are not end-to-end encrypted. You can block or report a member at any time."
       )},
      {gettext("Can I cancel my membership?"),
       gettext("Yes, at any time: your plan stays active until the end of the current period.")}
    ]
  end
end
