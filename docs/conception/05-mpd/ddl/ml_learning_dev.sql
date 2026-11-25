--
-- PostgreSQL database dump
--

-- Dumped from database version 14.17 (Homebrew)
-- Dumped by pg_dump version 14.17 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: lessons_track_revision(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.lessons_track_revision() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.revision := 1;
    NEW.revised_at := now();
  ELSIF (NEW.title, NEW.kind, NEW.body, NEW.content, NEW.solution)
        IS DISTINCT FROM (OLD.title, OLD.kind, OLD.body, OLD.content, OLD.solution) THEN
    NEW.revision := OLD.revision + 1;
    NEW.revised_at := now();
  ELSE
    NEW.revision := OLD.revision;
    NEW.revised_at := OLD.revised_at;
  END IF;
  RETURN NEW;
END
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: adventures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.adventures (
    id uuid NOT NULL,
    slug character varying(255) NOT NULL,
    title character varying(255) NOT NULL,
    summary text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    category character varying(255) NOT NULL,
    difficulty character varying(255) NOT NULL,
    premium boolean DEFAULT false NOT NULL,
    duration_minutes integer NOT NULL,
    cover character varying(255) NOT NULL,
    objectives text[] DEFAULT ARRAY[]::text[] NOT NULL,
    prerequisites text[] DEFAULT ARRAY[]::text[] NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    source character varying(255),
    external_id uuid,
    imported_version integer,
    author_id uuid,
    CONSTRAINT category_valid CHECK (((category)::text = ANY ((ARRAY['coding'::character varying, 'science'::character varying, 'humanities'::character varying, 'creative'::character varying])::text[]))),
    CONSTRAINT cover_valid CHECK (((cover)::text = ANY ((ARRAY['forest'::character varying, 'observatory'::character varying, 'alchemy'::character varying, 'archive'::character varying])::text[]))),
    CONSTRAINT difficulty_valid CHECK (((difficulty)::text = ANY ((ARRAY['beginner'::character varying, 'intermediate'::character varying, 'advanced'::character varying])::text[]))),
    CONSTRAINT duration_positive CHECK ((duration_minutes > 0)),
    CONSTRAINT import_fields_consistent CHECK ((((source IS NULL) = (external_id IS NULL)) AND ((external_id IS NULL) = (imported_version IS NULL))))
);


--
-- Name: badges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.badges (
    id uuid NOT NULL,
    slug character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    description text NOT NULL,
    icon character varying(255) NOT NULL,
    rarity character varying(255) NOT NULL,
    criterion character varying(255) NOT NULL,
    param character varying(255),
    target integer NOT NULL,
    "position" integer NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT criterion_valid CHECK (((criterion)::text = ANY ((ARRAY['lessons_completed'::character varying, 'lesson_completed'::character varying, 'adventures_completed'::character varying, 'total_xp'::character varying, 'level'::character varying, 'streak_days'::character varying, 'multiplayer_wins'::character varying])::text[]))),
    CONSTRAINT icon_allowed CHECK (((icon)::text = ANY ((ARRAY['hero-sparkles'::character varying, 'hero-sun'::character varying, 'hero-flag'::character varying, 'hero-star'::character varying, 'hero-bolt'::character varying, 'hero-academic-cap'::character varying, 'hero-trophy'::character varying, 'hero-fire'::character varying, 'hero-moon'::character varying, 'hero-users'::character varying, 'hero-book-open'::character varying, 'hero-shield-check'::character varying, 'hero-light-bulb'::character varying, 'hero-puzzle-piece'::character varying, 'hero-map'::character varying, 'hero-beaker'::character varying, 'hero-rocket-launch'::character varying, 'hero-pencil-square'::character varying])::text[]))),
    CONSTRAINT rarity_valid CHECK (((rarity)::text = ANY ((ARRAY['common'::character varying, 'uncommon'::character varying, 'rare'::character varying, 'epic'::character varying, 'legendary'::character varying])::text[]))),
    CONSTRAINT target_positive CHECK ((target > 0))
);


--
-- Name: chapters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.chapters (
    id uuid NOT NULL,
    adventure_id uuid NOT NULL,
    "position" integer NOT NULL,
    title character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: enrollments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.enrollments (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    adventure_id uuid NOT NULL,
    last_lesson_id uuid,
    completed_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: idempotent_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.idempotent_actions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    key uuid NOT NULL,
    lesson_id uuid NOT NULL,
    action character varying(255) NOT NULL,
    request_hash character varying(255) NOT NULL,
    response jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT action_valid CHECK (((action)::text = ANY ((ARRAY['submit'::character varying, 'complete'::character varying])::text[])))
);


--
-- Name: lesson_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lesson_progress (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    lesson_id uuid NOT NULL,
    status character varying(255) DEFAULT 'in_progress'::character varying NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    notes text,
    draft text,
    completed_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    notes_saved_at timestamp(0) without time zone,
    CONSTRAINT attempts_nonneg CHECK ((attempts >= 0)),
    CONSTRAINT status_valid CHECK (((status)::text = ANY ((ARRAY['in_progress'::character varying, 'completed'::character varying])::text[])))
);


--
-- Name: lessons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lessons (
    id uuid NOT NULL,
    chapter_id uuid NOT NULL,
    "position" integer NOT NULL,
    title character varying(255) NOT NULL,
    kind character varying(255) NOT NULL,
    body text DEFAULT ''::text NOT NULL,
    content jsonb DEFAULT '{}'::jsonb NOT NULL,
    solution jsonb DEFAULT '{}'::jsonb NOT NULL,
    xp_reward integer NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    revision integer DEFAULT 1 NOT NULL,
    revised_at timestamp(0) without time zone DEFAULT now() NOT NULL,
    CONSTRAINT kind_valid CHECK (((kind)::text = ANY ((ARRAY['story'::character varying, 'exercise'::character varying, 'coding'::character varying, 'video'::character varying, 'simulation'::character varying, 'minigame'::character varying])::text[]))),
    CONSTRAINT revision_positive CHECK ((revision > 0)),
    CONSTRAINT xp_reward_positive CHECK ((xp_reward > 0))
);


--
-- Name: quests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quests (
    id uuid NOT NULL,
    slug character varying(255) NOT NULL,
    title character varying(255) NOT NULL,
    description text NOT NULL,
    kind character varying(255) NOT NULL,
    target integer NOT NULL,
    xp_reward integer NOT NULL,
    "position" integer NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT kind_valid CHECK (((kind)::text = ANY ((ARRAY['lessons_completed'::character varying, 'xp_earned'::character varying, 'note_written'::character varying])::text[]))),
    CONSTRAINT target_positive CHECK ((target > 0)),
    CONSTRAINT xp_reward_range CHECK (((xp_reward >= 1) AND (xp_reward <= 500)))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: user_badges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_badges (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    badge_id uuid NOT NULL,
    earned_at timestamp(0) without time zone NOT NULL,
    equipped boolean DEFAULT false NOT NULL,
    "position" integer,
    CONSTRAINT equipped_position CHECK (((equipped AND ("position" IS NOT NULL) AND (("position" >= 1) AND ("position" <= 3))) OR ((NOT equipped) AND ("position" IS NULL))))
);


--
-- Name: xp_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.xp_events (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    ref_key character varying(255) NOT NULL,
    amount integer NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT amount_positive CHECK ((amount > 0))
);


--
-- Name: adventures adventures_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.adventures
    ADD CONSTRAINT adventures_pkey PRIMARY KEY (id);


--
-- Name: badges badges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.badges
    ADD CONSTRAINT badges_pkey PRIMARY KEY (id);


--
-- Name: chapters chapters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chapters
    ADD CONSTRAINT chapters_pkey PRIMARY KEY (id);


--
-- Name: enrollments enrollments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_pkey PRIMARY KEY (id);


--
-- Name: idempotent_actions idempotent_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.idempotent_actions
    ADD CONSTRAINT idempotent_actions_pkey PRIMARY KEY (id);


--
-- Name: lesson_progress lesson_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_progress
    ADD CONSTRAINT lesson_progress_pkey PRIMARY KEY (id);


--
-- Name: lessons lessons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_pkey PRIMARY KEY (id);


--
-- Name: quests quests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quests
    ADD CONSTRAINT quests_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: user_badges user_badges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_badges
    ADD CONSTRAINT user_badges_pkey PRIMARY KEY (id);


--
-- Name: xp_events xp_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.xp_events
    ADD CONSTRAINT xp_events_pkey PRIMARY KEY (id);


--
-- Name: adventures_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX adventures_slug_index ON public.adventures USING btree (slug);


--
-- Name: adventures_source_external_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX adventures_source_external_id_index ON public.adventures USING btree (source, external_id) WHERE (external_id IS NOT NULL);


--
-- Name: badges_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX badges_slug_index ON public.badges USING btree (slug);


--
-- Name: chapters_adventure_id_position_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX chapters_adventure_id_position_index ON public.chapters USING btree (adventure_id, "position");


--
-- Name: enrollments_user_id_adventure_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX enrollments_user_id_adventure_id_index ON public.enrollments USING btree (user_id, adventure_id);


--
-- Name: enrollments_user_id_updated_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX enrollments_user_id_updated_at_index ON public.enrollments USING btree (user_id, updated_at);


--
-- Name: idempotent_actions_lesson_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idempotent_actions_lesson_id_index ON public.idempotent_actions USING btree (lesson_id);


--
-- Name: idempotent_actions_user_id_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idempotent_actions_user_id_key_index ON public.idempotent_actions USING btree (user_id, key);


--
-- Name: lesson_progress_lesson_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lesson_progress_lesson_id_index ON public.lesson_progress USING btree (lesson_id);


--
-- Name: lesson_progress_user_id_lesson_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX lesson_progress_user_id_lesson_id_index ON public.lesson_progress USING btree (user_id, lesson_id);


--
-- Name: lessons_chapter_id_position_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX lessons_chapter_id_position_index ON public.lessons USING btree (chapter_id, "position");


--
-- Name: quests_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX quests_slug_index ON public.quests USING btree (slug);


--
-- Name: user_badges_badge_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_badges_badge_id_index ON public.user_badges USING btree (badge_id);


--
-- Name: user_badges_user_id_badge_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_badges_user_id_badge_id_index ON public.user_badges USING btree (user_id, badge_id);


--
-- Name: user_badges_user_id_position_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_badges_user_id_position_index ON public.user_badges USING btree (user_id, "position");


--
-- Name: xp_events_user_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX xp_events_user_id_inserted_at_index ON public.xp_events USING btree (user_id, inserted_at);


--
-- Name: xp_events_user_id_ref_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX xp_events_user_id_ref_key_index ON public.xp_events USING btree (user_id, ref_key);


--
-- Name: lessons lessons_track_revision; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER lessons_track_revision BEFORE INSERT OR UPDATE ON public.lessons FOR EACH ROW EXECUTE FUNCTION public.lessons_track_revision();


--
-- Name: chapters chapters_adventure_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.chapters
    ADD CONSTRAINT chapters_adventure_id_fkey FOREIGN KEY (adventure_id) REFERENCES public.adventures(id) ON DELETE CASCADE;


--
-- Name: enrollments enrollments_adventure_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_adventure_id_fkey FOREIGN KEY (adventure_id) REFERENCES public.adventures(id) ON DELETE CASCADE;


--
-- Name: enrollments enrollments_last_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.enrollments
    ADD CONSTRAINT enrollments_last_lesson_id_fkey FOREIGN KEY (last_lesson_id) REFERENCES public.lessons(id) ON DELETE SET NULL;


--
-- Name: idempotent_actions idempotent_actions_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.idempotent_actions
    ADD CONSTRAINT idempotent_actions_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id) ON DELETE CASCADE;


--
-- Name: lesson_progress lesson_progress_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lesson_progress
    ADD CONSTRAINT lesson_progress_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id) ON DELETE CASCADE;


--
-- Name: lessons lessons_chapter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_chapter_id_fkey FOREIGN KEY (chapter_id) REFERENCES public.chapters(id) ON DELETE CASCADE;


--
-- Name: user_badges user_badges_badge_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_badges
    ADD CONSTRAINT user_badges_badge_id_fkey FOREIGN KEY (badge_id) REFERENCES public.badges(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

