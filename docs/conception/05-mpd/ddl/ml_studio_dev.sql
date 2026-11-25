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
-- Name: oban_job_state; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.oban_job_state AS ENUM (
    'available',
    'suspended',
    'scheduled',
    'executing',
    'retryable',
    'completed',
    'discarded',
    'cancelled'
);


--
-- Name: studio_versions_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.studio_versions_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'versions are immutable';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: collaborators; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.collaborators (
    id uuid NOT NULL,
    project_id uuid NOT NULL,
    user_id uuid NOT NULL,
    username character varying(255) NOT NULL,
    role character varying(255) NOT NULL,
    invited_by uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT collaborators_role CHECK (((role)::text = ANY ((ARRAY['editor'::character varying, 'viewer'::character varying])::text[])))
);


--
-- Name: generations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.generations (
    id uuid NOT NULL,
    project_id uuid NOT NULL,
    lesson_id uuid,
    user_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    cost integer NOT NULL,
    provider character varying(255) NOT NULL,
    model character varying(255),
    brief text NOT NULL,
    result jsonb,
    error character varying(255),
    credits character varying(255) DEFAULT 'reserved'::character varying NOT NULL,
    retry_of uuid,
    applied_at timestamp(0) without time zone,
    started_at timestamp(0) without time zone,
    finished_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT generations_credits CHECK (((credits)::text = ANY ((ARRAY['reserved'::character varying, 'consumed'::character varying, 'released'::character varying])::text[]))),
    CONSTRAINT generations_kind CHECK (((kind)::text = ANY ((ARRAY['outline'::character varying, 'lesson_draft'::character varying, 'feedback'::character varying, 'image'::character varying])::text[]))),
    CONSTRAINT generations_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'running'::character varying, 'succeeded'::character varying, 'failed'::character varying, 'cancelled'::character varying])::text[])))
);


--
-- Name: images; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.images (
    id uuid NOT NULL,
    project_id uuid NOT NULL,
    lesson_id uuid,
    uploader_id uuid NOT NULL,
    alt text DEFAULT ''::text NOT NULL,
    content_type character varying(255) NOT NULL,
    byte_size integer NOT NULL,
    source character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT images_size CHECK (((byte_size > 0) AND (byte_size <= 2097152))),
    CONSTRAINT images_source CHECK (((source)::text = ANY ((ARRAY['upload'::character varying, 'demo'::character varying])::text[]))),
    CONSTRAINT images_type CHECK (((content_type)::text = ANY ((ARRAY['image/png'::character varying, 'image/jpeg'::character varying, 'image/webp'::character varying, 'image/svg+xml'::character varying])::text[])))
);


--
-- Name: lessons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lessons (
    id uuid NOT NULL,
    project_id uuid NOT NULL,
    module_id uuid NOT NULL,
    "position" integer NOT NULL,
    title character varying(255) NOT NULL,
    kind character varying(255) NOT NULL,
    body text DEFAULT ''::text NOT NULL,
    xp_reward integer DEFAULT 10 NOT NULL,
    content jsonb DEFAULT '{}'::jsonb NOT NULL,
    lock_version integer DEFAULT 1 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT lessons_kind CHECK (((kind)::text = ANY ((ARRAY['story'::character varying, 'exercise'::character varying, 'coding'::character varying, 'video'::character varying, 'simulation'::character varying, 'minigame'::character varying])::text[])))
);


--
-- Name: media; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.media (
    id uuid NOT NULL,
    project_id uuid NOT NULL,
    uploader_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    content_type character varying(255) NOT NULL,
    byte_size integer NOT NULL,
    lang character varying(255),
    label character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT media_kind_type CHECK (((((kind)::text = 'video'::text) AND ((content_type)::text = ANY ((ARRAY['video/webm'::character varying, 'video/mp4'::character varying])::text[]))) OR (((kind)::text = 'captions'::text) AND ((content_type)::text = 'text/vtt'::text) AND (lang IS NOT NULL) AND (label IS NOT NULL)))),
    CONSTRAINT media_size CHECK (((byte_size > 0) AND (byte_size <= 52428800)))
);


--
-- Name: member_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.member_settings (
    user_id uuid NOT NULL,
    share_drafts_with_ai boolean DEFAULT false NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: modules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.modules (
    id uuid NOT NULL,
    project_id uuid NOT NULL,
    "position" integer NOT NULL,
    title character varying(255) NOT NULL,
    lock_version integer DEFAULT 1 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: oban_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oban_jobs (
    id bigint NOT NULL,
    state public.oban_job_state DEFAULT 'available'::public.oban_job_state NOT NULL,
    queue text DEFAULT 'default'::text NOT NULL,
    worker text NOT NULL,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    errors jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 20 NOT NULL,
    inserted_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    scheduled_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    attempted_at timestamp without time zone,
    completed_at timestamp without time zone,
    attempted_by text[],
    discarded_at timestamp without time zone,
    priority integer DEFAULT 0 NOT NULL,
    tags text[] DEFAULT ARRAY[]::text[],
    meta jsonb DEFAULT '{}'::jsonb,
    cancelled_at timestamp without time zone,
    CONSTRAINT attempt_range CHECK (((attempt >= 0) AND (attempt <= max_attempts))),
    CONSTRAINT positive_max_attempts CHECK ((max_attempts > 0)),
    CONSTRAINT queue_length CHECK (((char_length(queue) > 0) AND (char_length(queue) < 128))),
    CONSTRAINT worker_length CHECK (((char_length(worker) > 0) AND (char_length(worker) < 128)))
);


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oban_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oban_jobs_id_seq OWNED BY public.oban_jobs.id;


--
-- Name: oban_peers; Type: TABLE; Schema: public; Owner: -
--

CREATE UNLOGGED TABLE public.oban_peers (
    name text NOT NULL,
    node text NOT NULL,
    started_at timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL
);


--
-- Name: projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.projects (
    id uuid NOT NULL,
    owner_id uuid,
    title character varying(255) NOT NULL,
    summary text DEFAULT ''::text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    objectives text[] DEFAULT ARRAY[]::text[] NOT NULL,
    prerequisites text[] DEFAULT ARRAY[]::text[] NOT NULL,
    audience text DEFAULT ''::text NOT NULL,
    level character varying(255) DEFAULT 'beginner'::character varying NOT NULL,
    duration_minutes integer DEFAULT 30 NOT NULL,
    category character varying(255) DEFAULT 'creative'::character varying NOT NULL,
    cover character varying(255) DEFAULT 'forest'::character varying NOT NULL,
    status character varying(255) DEFAULT 'draft'::character varying NOT NULL,
    lock_version integer DEFAULT 1 NOT NULL,
    content_revision integer DEFAULT 1 NOT NULL,
    attestations jsonb,
    attested_revision integer,
    attested_at timestamp(0) without time zone,
    review_version integer,
    submitted_at timestamp(0) without time zone,
    reviewed_by uuid,
    reviewed_at timestamp(0) without time zone,
    review_reason text,
    import_message text,
    published_slug character varying(255),
    published_adventure_id character varying(255),
    published_version integer,
    published_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT projects_category CHECK (((category)::text = ANY ((ARRAY['coding'::character varying, 'science'::character varying, 'humanities'::character varying, 'creative'::character varying])::text[]))),
    CONSTRAINT projects_cover CHECK (((cover)::text = ANY ((ARRAY['forest'::character varying, 'observatory'::character varying, 'alchemy'::character varying, 'archive'::character varying])::text[]))),
    CONSTRAINT projects_level CHECK (((level)::text = ANY ((ARRAY['beginner'::character varying, 'intermediate'::character varying, 'advanced'::character varying])::text[]))),
    CONSTRAINT projects_status CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'submitted'::character varying, 'approved'::character varying, 'published'::character varying])::text[])))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: versions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.versions (
    id uuid NOT NULL,
    project_id uuid NOT NULL,
    number integer NOT NULL,
    note character varying(255) DEFAULT ''::character varying NOT NULL,
    source character varying(255) NOT NULL,
    author_id uuid NOT NULL,
    snapshot jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT versions_source CHECK (((source)::text = ANY ((ARRAY['manual'::character varying, 'submission'::character varying, 'restore'::character varying])::text[])))
);


--
-- Name: oban_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);


--
-- Name: collaborators collaborators_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collaborators
    ADD CONSTRAINT collaborators_pkey PRIMARY KEY (id);


--
-- Name: generations generations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generations
    ADD CONSTRAINT generations_pkey PRIMARY KEY (id);


--
-- Name: images images_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.images
    ADD CONSTRAINT images_pkey PRIMARY KEY (id);


--
-- Name: lessons lessons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_pkey PRIMARY KEY (id);


--
-- Name: lessons lessons_position_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_position_unique UNIQUE (module_id, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: media media_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.media
    ADD CONSTRAINT media_pkey PRIMARY KEY (id);


--
-- Name: member_settings member_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.member_settings
    ADD CONSTRAINT member_settings_pkey PRIMARY KEY (user_id);


--
-- Name: modules modules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modules
    ADD CONSTRAINT modules_pkey PRIMARY KEY (id);


--
-- Name: modules modules_position_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modules
    ADD CONSTRAINT modules_position_unique UNIQUE (project_id, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: oban_jobs non_negative_priority; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.oban_jobs
    ADD CONSTRAINT non_negative_priority CHECK ((priority >= 0)) NOT VALID;


--
-- Name: oban_jobs oban_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs
    ADD CONSTRAINT oban_jobs_pkey PRIMARY KEY (id);


--
-- Name: oban_peers oban_peers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_peers
    ADD CONSTRAINT oban_peers_pkey PRIMARY KEY (name);


--
-- Name: projects projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: versions versions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versions
    ADD CONSTRAINT versions_pkey PRIMARY KEY (id);


--
-- Name: collaborators_project_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX collaborators_project_id_user_id_index ON public.collaborators USING btree (project_id, user_id);


--
-- Name: collaborators_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX collaborators_user_id_index ON public.collaborators USING btree (user_id);


--
-- Name: generations_project_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX generations_project_id_inserted_at_index ON public.generations USING btree (project_id, inserted_at);


--
-- Name: generations_user_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX generations_user_id_inserted_at_index ON public.generations USING btree (user_id, inserted_at);


--
-- Name: images_project_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX images_project_id_index ON public.images USING btree (project_id);


--
-- Name: lessons_project_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lessons_project_id_index ON public.lessons USING btree (project_id);


--
-- Name: media_project_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_project_id_index ON public.media USING btree (project_id);


--
-- Name: oban_jobs_args_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_args_index ON public.oban_jobs USING gin (args);


--
-- Name: oban_jobs_meta_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_meta_index ON public.oban_jobs USING gin (meta);


--
-- Name: oban_jobs_state_cancelled_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_cancelled_at_index ON public.oban_jobs USING btree (state, cancelled_at);


--
-- Name: oban_jobs_state_discarded_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_discarded_at_index ON public.oban_jobs USING btree (state, discarded_at);


--
-- Name: oban_jobs_state_queue_priority_scheduled_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index ON public.oban_jobs USING btree (state, queue, priority, scheduled_at, id);


--
-- Name: projects_owner_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX projects_owner_id_index ON public.projects USING btree (owner_id);


--
-- Name: projects_status_submitted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX projects_status_submitted_at_index ON public.projects USING btree (status, submitted_at);


--
-- Name: versions_project_id_number_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX versions_project_id_number_index ON public.versions USING btree (project_id, number);


--
-- Name: versions versions_no_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER versions_no_update BEFORE UPDATE ON public.versions FOR EACH ROW EXECUTE FUNCTION public.studio_versions_immutable();


--
-- Name: collaborators collaborators_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collaborators
    ADD CONSTRAINT collaborators_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: generations generations_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generations
    ADD CONSTRAINT generations_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id) ON DELETE SET NULL;


--
-- Name: generations generations_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generations
    ADD CONSTRAINT generations_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: images images_lesson_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.images
    ADD CONSTRAINT images_lesson_id_fkey FOREIGN KEY (lesson_id) REFERENCES public.lessons(id) ON DELETE SET NULL;


--
-- Name: images images_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.images
    ADD CONSTRAINT images_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: lessons lessons_module_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_module_id_fkey FOREIGN KEY (module_id) REFERENCES public.modules(id) ON DELETE CASCADE;


--
-- Name: lessons lessons_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lessons
    ADD CONSTRAINT lessons_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: media media_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.media
    ADD CONSTRAINT media_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: modules modules_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modules
    ADD CONSTRAINT modules_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- Name: versions versions_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.versions
    ADD CONSTRAINT versions_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.projects(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

