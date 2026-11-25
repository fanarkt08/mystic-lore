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
-- Name: credit_entries_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.credit_entries_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'credit_entries rows are immutable';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: checkout_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.checkout_sessions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    plan character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    provider character varying(255) NOT NULL,
    provider_session_id character varying(255) NOT NULL,
    expires_at timestamp(0) without time zone NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT checkout_plan CHECK (((plan)::text = ANY ((ARRAY['premium'::character varying, 'vip'::character varying])::text[]))),
    CONSTRAINT checkout_status CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'completed'::character varying])::text[])))
);


--
-- Name: credit_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credit_accounts (
    user_id uuid NOT NULL,
    period character varying(255),
    plan character varying(255),
    allocation integer DEFAULT 0 NOT NULL,
    balance integer DEFAULT 0 NOT NULL,
    reserved integer DEFAULT 0 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT credit_allocation_non_negative CHECK ((allocation >= 0)),
    CONSTRAINT credit_balance_non_negative CHECK ((balance >= 0)),
    CONSTRAINT credit_reserved_non_negative CHECK ((reserved >= 0))
);


--
-- Name: credit_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credit_entries (
    id uuid NOT NULL,
    seq bigint NOT NULL,
    user_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    amount integer NOT NULL,
    delta integer NOT NULL,
    balance_after integer NOT NULL,
    ref character varying(255) NOT NULL,
    reason character varying(255),
    period character varying(255) NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT credit_entry_amount CHECK ((amount > 0)),
    CONSTRAINT credit_entry_balance CHECK ((balance_after >= 0)),
    CONSTRAINT credit_entry_kind CHECK (((kind)::text = ANY ((ARRAY['allocation'::character varying, 'top_up'::character varying, 'reservation'::character varying, 'consumption'::character varying, 'release'::character varying, 'expiration'::character varying, 'adjustment'::character varying])::text[])))
);


--
-- Name: credit_entries_seq_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.credit_entries_seq_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: credit_entries_seq_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.credit_entries_seq_seq OWNED BY public.credit_entries.seq;


--
-- Name: invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoices (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    provider character varying(255) NOT NULL,
    provider_invoice_id character varying(255) NOT NULL,
    provider_subscription_id character varying(255),
    amount_cents integer NOT NULL,
    currency character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    period_start timestamp(0) without time zone,
    period_end timestamp(0) without time zone,
    hosted_url text,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT invoices_amount CHECK ((amount_cents >= 0)),
    CONSTRAINT invoices_status CHECK (((status)::text = ANY ((ARRAY['paid'::character varying, 'failed'::character varying])::text[])))
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
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscriptions (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    plan character varying(255) DEFAULT 'free'::character varying NOT NULL,
    status character varying(255) DEFAULT 'none'::character varying NOT NULL,
    provider character varying(255) NOT NULL,
    provider_customer_id character varying(255),
    provider_subscription_id character varying(255),
    current_period_start timestamp(0) without time zone,
    current_period_end timestamp(0) without time zone,
    cancel_at_period_end boolean DEFAULT false NOT NULL,
    past_due_since timestamp(0) without time zone,
    last_event_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT subscriptions_plan CHECK (((plan)::text = ANY ((ARRAY['free'::character varying, 'premium'::character varying, 'vip'::character varying])::text[]))),
    CONSTRAINT subscriptions_provider CHECK (((provider)::text = ANY ((ARRAY['local'::character varying, 'stripe'::character varying])::text[]))),
    CONSTRAINT subscriptions_status CHECK (((status)::text = ANY ((ARRAY['none'::character varying, 'active'::character varying, 'past_due'::character varying, 'canceled'::character varying])::text[])))
);


--
-- Name: webhook_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.webhook_events (
    id uuid NOT NULL,
    provider character varying(255) NOT NULL,
    provider_event_id character varying(255) NOT NULL,
    type character varying(255) NOT NULL,
    event_created_at timestamp(0) without time zone NOT NULL,
    user_id uuid,
    status character varying(255) NOT NULL,
    error character varying(255),
    payload jsonb NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    CONSTRAINT webhook_events_status CHECK (((status)::text = ANY ((ARRAY['received'::character varying, 'processed'::character varying, 'ignored'::character varying, 'stale'::character varying, 'failed'::character varying])::text[])))
);


--
-- Name: credit_entries seq; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credit_entries ALTER COLUMN seq SET DEFAULT nextval('public.credit_entries_seq_seq'::regclass);


--
-- Name: oban_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);


--
-- Name: checkout_sessions checkout_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.checkout_sessions
    ADD CONSTRAINT checkout_sessions_pkey PRIMARY KEY (id);


--
-- Name: credit_accounts credit_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credit_accounts
    ADD CONSTRAINT credit_accounts_pkey PRIMARY KEY (user_id);


--
-- Name: credit_entries credit_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credit_entries
    ADD CONSTRAINT credit_entries_pkey PRIMARY KEY (id);


--
-- Name: invoices invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_pkey PRIMARY KEY (id);


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
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (id);


--
-- Name: webhook_events webhook_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.webhook_events
    ADD CONSTRAINT webhook_events_pkey PRIMARY KEY (id);


--
-- Name: checkout_sessions_provider_provider_session_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX checkout_sessions_provider_provider_session_id_index ON public.checkout_sessions USING btree (provider, provider_session_id);


--
-- Name: checkout_sessions_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX checkout_sessions_user_id_index ON public.checkout_sessions USING btree (user_id);


--
-- Name: credit_entries_user_id_kind_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX credit_entries_user_id_kind_ref_index ON public.credit_entries USING btree (user_id, kind, ref);


--
-- Name: credit_entries_user_id_seq_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX credit_entries_user_id_seq_index ON public.credit_entries USING btree (user_id, seq);


--
-- Name: invoices_provider_provider_invoice_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX invoices_provider_provider_invoice_id_index ON public.invoices USING btree (provider, provider_invoice_id);


--
-- Name: invoices_user_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX invoices_user_id_inserted_at_index ON public.invoices USING btree (user_id, inserted_at);


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
-- Name: subscriptions_provider_provider_customer_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX subscriptions_provider_provider_customer_id_index ON public.subscriptions USING btree (provider, provider_customer_id);


--
-- Name: subscriptions_provider_provider_subscription_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX subscriptions_provider_provider_subscription_id_index ON public.subscriptions USING btree (provider, provider_subscription_id);


--
-- Name: subscriptions_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX subscriptions_user_id_index ON public.subscriptions USING btree (user_id);


--
-- Name: webhook_events_provider_provider_event_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX webhook_events_provider_provider_event_id_index ON public.webhook_events USING btree (provider, provider_event_id);


--
-- Name: webhook_events_status_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX webhook_events_status_inserted_at_index ON public.webhook_events USING btree (status, inserted_at);


--
-- Name: credit_entries credit_entries_no_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER credit_entries_no_update BEFORE UPDATE ON public.credit_entries FOR EACH ROW EXECUTE FUNCTION public.credit_entries_immutable();


--
-- PostgreSQL database dump complete
--

