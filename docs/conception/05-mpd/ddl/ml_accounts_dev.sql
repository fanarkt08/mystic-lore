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
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


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
-- Name: audit_entries_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_entries_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'audit_entries rows are append-only';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: audit_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_entries (
    id bigint NOT NULL,
    service character varying(255) NOT NULL,
    actor_id uuid NOT NULL,
    action character varying(255) NOT NULL,
    target_type character varying(255),
    target_id character varying(255),
    reason text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: audit_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_entries_id_seq OWNED BY public.audit_entries.id;


--
-- Name: confirmation_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.confirmation_tokens (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    token_hash bytea NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: data_exports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.data_exports (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    data jsonb,
    failed_services character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    completed_at timestamp(0) without time zone,
    expires_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT data_exports_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'ready'::character varying, 'failed'::character varying])::text[])))
);


--
-- Name: deletion_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deletion_steps (
    user_id uuid NOT NULL,
    service character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: incident_updates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.incident_updates (
    id uuid NOT NULL,
    incident_id uuid NOT NULL,
    author_id uuid NOT NULL,
    body text NOT NULL,
    status character varying(255),
    severity character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: incidents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.incidents (
    id uuid NOT NULL,
    title character varying(255) NOT NULL,
    severity character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    summary text,
    created_by uuid NOT NULL,
    resolved_by uuid,
    resolved_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT incidents_resolution CHECK ((((status)::text <> 'resolved'::text) OR ((summary IS NOT NULL) AND (resolved_at IS NOT NULL) AND (resolved_by IS NOT NULL)))),
    CONSTRAINT incidents_severity CHECK (((severity)::text = ANY ((ARRAY['low'::character varying, 'medium'::character varying, 'high'::character varying, 'critical'::character varying])::text[]))),
    CONSTRAINT incidents_status CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'investigating'::character varying, 'resolved'::character varying])::text[])))
);


--
-- Name: login_challenges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.login_challenges (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    token_hash bytea NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: login_failures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.login_failures (
    id bigint NOT NULL,
    email character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: login_failures_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.login_failures_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: login_failures_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.login_failures_id_seq OWNED BY public.login_failures.id;


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
-- Name: recovery_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recovery_codes (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    code_hash bytea NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: sanction_appeals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sanction_appeals (
    id uuid NOT NULL,
    sanction_id uuid NOT NULL,
    user_id uuid NOT NULL,
    body text NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    decided_by uuid,
    decision_reason text,
    decided_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT sanction_appeals_status CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'accepted'::character varying, 'rejected'::character varying])::text[])))
);


--
-- Name: sanctions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sanctions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    reason text NOT NULL,
    issued_by uuid NOT NULL,
    ends_at timestamp(0) without time zone,
    ref character varying(255),
    lifted_at timestamp(0) without time zone,
    lifted_by uuid,
    lift_reason text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT sanctions_kind CHECK (((((kind)::text = 'warning'::text) AND (ends_at IS NULL)) OR (((kind)::text = 'restriction'::text) AND (ends_at IS NOT NULL))))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sessions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    token_hash bytea NOT NULL,
    last_used_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    user_agent character varying(200),
    ip character varying(45)
);


--
-- Name: support_replies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_replies (
    id uuid NOT NULL,
    request_id uuid NOT NULL,
    author_id uuid NOT NULL,
    body text NOT NULL,
    email_status character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: support_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_requests (
    id uuid NOT NULL,
    reference character varying(255) NOT NULL,
    user_id uuid,
    email character varying(255),
    topic character varying(255) NOT NULL,
    message text NOT NULL,
    locale character varying(255) DEFAULT 'en'::character varying NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    internal_note text,
    answered_at timestamp(0) without time zone,
    closed_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT support_requests_requester CHECK (((user_id IS NULL) <> (email IS NULL))),
    CONSTRAINT support_requests_status CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'answered'::character varying, 'closed'::character varying])::text[]))),
    CONSTRAINT support_requests_topic CHECK (((topic)::text = ANY ((ARRAY['account'::character varying, 'billing'::character varying, 'privacy'::character varying, 'bug'::character varying, 'other'::character varying])::text[])))
);


--
-- Name: throttle_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.throttle_events (
    id bigint NOT NULL,
    key character varying(255) NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: throttle_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.throttle_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: throttle_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.throttle_events_id_seq OWNED BY public.throttle_events.id;


--
-- Name: user_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_tokens (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    context character varying(255) NOT NULL,
    token_hash bytea NOT NULL,
    sent_to public.citext NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT context_must_be_valid CHECK (((context)::text = ANY ((ARRAY['reset_password'::character varying, 'change_email'::character varying])::text[])))
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    email public.citext NOT NULL,
    username public.citext NOT NULL,
    display_name character varying(255) NOT NULL,
    bio text,
    hashed_password character varying(255) NOT NULL,
    role character varying(255) DEFAULT 'user'::character varying NOT NULL,
    confirmed_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    totp_secret bytea,
    totp_pending_secret bytea,
    totp_last_step bigint,
    totp_enabled_at timestamp(0) without time zone,
    deletion_scheduled_at timestamp(0) without time zone,
    deleted_at timestamp(0) without time zone,
    restricted_until timestamp(0) without time zone,
    pronouns character varying(255),
    interests character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    cover character varying(255),
    profile_visibility character varying(255) DEFAULT 'members'::character varying NOT NULL,
    avatar_crest character varying(255),
    avatar_image character varying(255),
    preferences jsonb DEFAULT '{}'::jsonb NOT NULL,
    onboarding_status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    onboarding_at timestamp(0) without time zone,
    CONSTRAINT role_must_be_valid CHECK (((role)::text = ANY ((ARRAY['user'::character varying, 'moderator'::character varying, 'admin'::character varying])::text[]))),
    CONSTRAINT users_onboarding_status CHECK (((onboarding_status)::text = ANY ((ARRAY['pending'::character varying, 'completed'::character varying, 'skipped'::character varying])::text[]))),
    CONSTRAINT users_one_avatar CHECK (((avatar_crest IS NULL) OR (avatar_image IS NULL))),
    CONSTRAINT users_profile_visibility CHECK (((profile_visibility)::text = ANY ((ARRAY['public'::character varying, 'members'::character varying, 'friends'::character varying, 'private'::character varying])::text[])))
);


--
-- Name: audit_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_entries ALTER COLUMN id SET DEFAULT nextval('public.audit_entries_id_seq'::regclass);


--
-- Name: login_failures id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login_failures ALTER COLUMN id SET DEFAULT nextval('public.login_failures_id_seq'::regclass);


--
-- Name: oban_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);


--
-- Name: throttle_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.throttle_events ALTER COLUMN id SET DEFAULT nextval('public.throttle_events_id_seq'::regclass);


--
-- Name: audit_entries audit_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_entries
    ADD CONSTRAINT audit_entries_pkey PRIMARY KEY (id);


--
-- Name: confirmation_tokens confirmation_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.confirmation_tokens
    ADD CONSTRAINT confirmation_tokens_pkey PRIMARY KEY (id);


--
-- Name: data_exports data_exports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.data_exports
    ADD CONSTRAINT data_exports_pkey PRIMARY KEY (id);


--
-- Name: deletion_steps deletion_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deletion_steps
    ADD CONSTRAINT deletion_steps_pkey PRIMARY KEY (user_id, service);


--
-- Name: incident_updates incident_updates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incident_updates
    ADD CONSTRAINT incident_updates_pkey PRIMARY KEY (id);


--
-- Name: incidents incidents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incidents
    ADD CONSTRAINT incidents_pkey PRIMARY KEY (id);


--
-- Name: login_challenges login_challenges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login_challenges
    ADD CONSTRAINT login_challenges_pkey PRIMARY KEY (id);


--
-- Name: login_failures login_failures_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login_failures
    ADD CONSTRAINT login_failures_pkey PRIMARY KEY (id);


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
-- Name: recovery_codes recovery_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_codes
    ADD CONSTRAINT recovery_codes_pkey PRIMARY KEY (id);


--
-- Name: sanction_appeals sanction_appeals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sanction_appeals
    ADD CONSTRAINT sanction_appeals_pkey PRIMARY KEY (id);


--
-- Name: sanctions sanctions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sanctions
    ADD CONSTRAINT sanctions_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: sessions sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);


--
-- Name: support_replies support_replies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_replies
    ADD CONSTRAINT support_replies_pkey PRIMARY KEY (id);


--
-- Name: support_requests support_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_requests
    ADD CONSTRAINT support_requests_pkey PRIMARY KEY (id);


--
-- Name: throttle_events throttle_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.throttle_events
    ADD CONSTRAINT throttle_events_pkey PRIMARY KEY (id);


--
-- Name: user_tokens user_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tokens
    ADD CONSTRAINT user_tokens_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: audit_entries_action_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_entries_action_inserted_at_index ON public.audit_entries USING btree (action, inserted_at);


--
-- Name: audit_entries_actor_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_entries_actor_id_inserted_at_index ON public.audit_entries USING btree (actor_id, inserted_at);


--
-- Name: audit_entries_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_entries_inserted_at_index ON public.audit_entries USING btree (inserted_at);


--
-- Name: confirmation_tokens_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX confirmation_tokens_token_hash_index ON public.confirmation_tokens USING btree (token_hash);


--
-- Name: confirmation_tokens_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX confirmation_tokens_user_id_index ON public.confirmation_tokens USING btree (user_id);


--
-- Name: data_exports_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX data_exports_expires_at_index ON public.data_exports USING btree (expires_at);


--
-- Name: data_exports_user_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX data_exports_user_id_inserted_at_index ON public.data_exports USING btree (user_id, inserted_at);


--
-- Name: incident_updates_incident_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX incident_updates_incident_id_inserted_at_index ON public.incident_updates USING btree (incident_id, inserted_at);


--
-- Name: incidents_status_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX incidents_status_inserted_at_index ON public.incidents USING btree (status, inserted_at);


--
-- Name: login_challenges_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX login_challenges_token_hash_index ON public.login_challenges USING btree (token_hash);


--
-- Name: login_challenges_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX login_challenges_user_id_index ON public.login_challenges USING btree (user_id);


--
-- Name: login_failures_email_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX login_failures_email_inserted_at_index ON public.login_failures USING btree (email, inserted_at);


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
-- Name: recovery_codes_user_id_code_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX recovery_codes_user_id_code_hash_index ON public.recovery_codes USING btree (user_id, code_hash);


--
-- Name: sanction_appeals_one_open_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sanction_appeals_one_open_index ON public.sanction_appeals USING btree (sanction_id) WHERE ((status)::text = 'open'::text);


--
-- Name: sanction_appeals_status_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sanction_appeals_status_inserted_at_index ON public.sanction_appeals USING btree (status, inserted_at);


--
-- Name: sanction_appeals_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sanction_appeals_user_id_index ON public.sanction_appeals USING btree (user_id);


--
-- Name: sanctions_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sanctions_ref_index ON public.sanctions USING btree (ref) WHERE (ref IS NOT NULL);


--
-- Name: sanctions_user_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sanctions_user_id_inserted_at_index ON public.sanctions USING btree (user_id, inserted_at);


--
-- Name: sessions_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sessions_token_hash_index ON public.sessions USING btree (token_hash);


--
-- Name: sessions_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sessions_user_id_index ON public.sessions USING btree (user_id);


--
-- Name: support_replies_request_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX support_replies_request_id_index ON public.support_replies USING btree (request_id);


--
-- Name: support_requests_closed_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX support_requests_closed_at_index ON public.support_requests USING btree (closed_at);


--
-- Name: support_requests_reference_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX support_requests_reference_index ON public.support_requests USING btree (reference);


--
-- Name: support_requests_status_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX support_requests_status_inserted_at_index ON public.support_requests USING btree (status, inserted_at);


--
-- Name: support_requests_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX support_requests_user_id_index ON public.support_requests USING btree (user_id);


--
-- Name: throttle_events_key_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX throttle_events_key_inserted_at_index ON public.throttle_events USING btree (key, inserted_at);


--
-- Name: user_tokens_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX user_tokens_token_hash_index ON public.user_tokens USING btree (token_hash);


--
-- Name: user_tokens_user_id_context_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_tokens_user_id_context_index ON public.user_tokens USING btree (user_id, context);


--
-- Name: users_avatar_image_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_avatar_image_index ON public.users USING btree (avatar_image) WHERE (avatar_image IS NOT NULL);


--
-- Name: users_deletion_due_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX users_deletion_due_index ON public.users USING btree (deletion_scheduled_at) WHERE ((deletion_scheduled_at IS NOT NULL) AND (deleted_at IS NULL));


--
-- Name: users_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_index ON public.users USING btree (email);


--
-- Name: users_username_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_username_index ON public.users USING btree (username);


--
-- Name: audit_entries audit_entries_no_change; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_entries_no_change BEFORE DELETE OR UPDATE ON public.audit_entries FOR EACH ROW EXECUTE FUNCTION public.audit_entries_append_only();


--
-- Name: confirmation_tokens confirmation_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.confirmation_tokens
    ADD CONSTRAINT confirmation_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: data_exports data_exports_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.data_exports
    ADD CONSTRAINT data_exports_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: deletion_steps deletion_steps_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deletion_steps
    ADD CONSTRAINT deletion_steps_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: incident_updates incident_updates_incident_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.incident_updates
    ADD CONSTRAINT incident_updates_incident_id_fkey FOREIGN KEY (incident_id) REFERENCES public.incidents(id) ON DELETE CASCADE;


--
-- Name: login_challenges login_challenges_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.login_challenges
    ADD CONSTRAINT login_challenges_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: recovery_codes recovery_codes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recovery_codes
    ADD CONSTRAINT recovery_codes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: sanction_appeals sanction_appeals_sanction_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sanction_appeals
    ADD CONSTRAINT sanction_appeals_sanction_id_fkey FOREIGN KEY (sanction_id) REFERENCES public.sanctions(id) ON DELETE CASCADE;


--
-- Name: sanction_appeals sanction_appeals_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sanction_appeals
    ADD CONSTRAINT sanction_appeals_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: sanctions sanctions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sanctions
    ADD CONSTRAINT sanctions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: sessions sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: support_replies support_replies_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_replies
    ADD CONSTRAINT support_replies_request_id_fkey FOREIGN KEY (request_id) REFERENCES public.support_requests(id) ON DELETE CASCADE;


--
-- Name: support_requests support_requests_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_requests
    ADD CONSTRAINT support_requests_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: user_tokens user_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_tokens
    ADD CONSTRAINT user_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

