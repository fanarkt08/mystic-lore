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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: email_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_log (
    id bigint NOT NULL,
    user_id uuid NOT NULL,
    dedupe_key character varying(255) NOT NULL,
    category character varying(255) NOT NULL,
    kind character varying(255) NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    sent_at timestamp without time zone
);


--
-- Name: email_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_log_id_seq OWNED BY public.email_log.id;


--
-- Name: notification_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_events (
    user_id uuid NOT NULL,
    event_id character varying(255) NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: notification_read_marks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_read_marks (
    user_id uuid NOT NULL,
    dedupe_key character varying(255) NOT NULL,
    read_at timestamp without time zone NOT NULL
);


--
-- Name: notification_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_settings (
    user_id uuid NOT NULL,
    channels jsonb DEFAULT '{}'::jsonb NOT NULL,
    quiet_enabled boolean DEFAULT false NOT NULL,
    quiet_start time(0) without time zone DEFAULT '22:00:00'::time without time zone NOT NULL,
    quiet_end time(0) without time zone DEFAULT '07:00:00'::time without time zone NOT NULL,
    time_zone character varying(255),
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    category character varying(255) NOT NULL,
    kind character varying(255) NOT NULL,
    actor_id uuid,
    subject_type character varying(255),
    subject_id character varying(255),
    params jsonb DEFAULT '{}'::jsonb NOT NULL,
    dedupe_key character varying(255) NOT NULL,
    count integer DEFAULT 1 NOT NULL,
    read_at timestamp without time zone,
    last_event_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT count_positive CHECK ((count >= 1))
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
-- Name: pending_emails; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pending_emails (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    notification_id uuid,
    category character varying(255) NOT NULL,
    kind character varying(255) NOT NULL,
    actor_id uuid,
    params jsonb DEFAULT '{}'::jsonb NOT NULL,
    dedupe_key character varying(255) NOT NULL,
    mandatory boolean DEFAULT false NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: email_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_log ALTER COLUMN id SET DEFAULT nextval('public.email_log_id_seq'::regclass);


--
-- Name: oban_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);


--
-- Name: email_log email_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_log
    ADD CONSTRAINT email_log_pkey PRIMARY KEY (id);


--
-- Name: oban_jobs non_negative_priority; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.oban_jobs
    ADD CONSTRAINT non_negative_priority CHECK ((priority >= 0)) NOT VALID;


--
-- Name: notification_events notification_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_events
    ADD CONSTRAINT notification_events_pkey PRIMARY KEY (user_id, event_id);


--
-- Name: notification_read_marks notification_read_marks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_read_marks
    ADD CONSTRAINT notification_read_marks_pkey PRIMARY KEY (user_id, dedupe_key);


--
-- Name: notification_settings notification_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_settings
    ADD CONSTRAINT notification_settings_pkey PRIMARY KEY (user_id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


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
-- Name: pending_emails pending_emails_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_emails
    ADD CONSTRAINT pending_emails_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: email_log_user_id_dedupe_key_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_log_user_id_dedupe_key_inserted_at_index ON public.email_log USING btree (user_id, dedupe_key, inserted_at);


--
-- Name: email_log_user_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_log_user_id_inserted_at_index ON public.email_log USING btree (user_id, inserted_at);


--
-- Name: notification_events_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notification_events_inserted_at_index ON public.notification_events USING btree (inserted_at);


--
-- Name: notification_read_marks_read_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notification_read_marks_read_at_index ON public.notification_read_marks USING btree (read_at);


--
-- Name: notifications_actor_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_actor_id_index ON public.notifications USING btree (actor_id);


--
-- Name: notifications_last_event_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_last_event_at_index ON public.notifications USING btree (last_event_at);


--
-- Name: notifications_unread_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notifications_unread_index ON public.notifications USING btree (user_id) WHERE (read_at IS NULL);


--
-- Name: notifications_unread_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX notifications_unread_key_index ON public.notifications USING btree (user_id, dedupe_key) WHERE (read_at IS NULL);


--
-- Name: notifications_user_id_last_event_at_DESC_id_DESC_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "notifications_user_id_last_event_at_DESC_id_DESC_index" ON public.notifications USING btree (user_id, last_event_at DESC, id DESC);


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
-- Name: pending_emails_user_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pending_emails_user_id_inserted_at_index ON public.pending_emails USING btree (user_id, inserted_at);


--
-- PostgreSQL database dump complete
--

