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

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categories (
    slug character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    description character varying(255) NOT NULL,
    "position" integer NOT NULL,
    staff_only boolean DEFAULT false NOT NULL
);


--
-- Name: discussions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.discussions (
    id uuid NOT NULL,
    category character varying(255) NOT NULL,
    author_id uuid NOT NULL,
    title character varying(140) NOT NULL,
    slug character varying(255) NOT NULL,
    body text NOT NULL,
    status character varying(255) DEFAULT 'visible'::character varying NOT NULL,
    pinned boolean DEFAULT false NOT NULL,
    locked boolean DEFAULT false NOT NULL,
    solution_reply_id uuid,
    helpful_count integer DEFAULT 0 NOT NULL,
    moderation_reason text,
    edited_at timestamp without time zone,
    last_activity_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT discussions_helpful_count CHECK ((helpful_count >= 0)),
    CONSTRAINT discussions_status CHECK (((status)::text = ANY ((ARRAY['visible'::character varying, 'hidden'::character varying, 'removed'::character varying, 'deleted'::character varying])::text[])))
);


--
-- Name: follows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.follows (
    user_id uuid NOT NULL,
    discussion_id uuid NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: moderation_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.moderation_log (
    id uuid NOT NULL,
    moderator_id uuid NOT NULL,
    action character varying(255) NOT NULL,
    target_type character varying(255) NOT NULL,
    target_id uuid NOT NULL,
    reason text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL
);


--
-- Name: replies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.replies (
    id uuid NOT NULL,
    discussion_id uuid NOT NULL,
    author_id uuid NOT NULL,
    body text NOT NULL,
    status character varying(255) DEFAULT 'visible'::character varying NOT NULL,
    helpful_count integer DEFAULT 0 NOT NULL,
    moderation_reason text,
    edited_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT replies_helpful_count CHECK ((helpful_count >= 0)),
    CONSTRAINT replies_status CHECK (((status)::text = ANY ((ARRAY['visible'::character varying, 'hidden'::character varying, 'removed'::character varying, 'deleted'::character varying])::text[])))
);


--
-- Name: reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reports (
    id uuid NOT NULL,
    reporter_id uuid NOT NULL,
    target_type character varying(255) NOT NULL,
    target_id uuid NOT NULL,
    reason character varying(255) NOT NULL,
    details text,
    snapshot jsonb NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    resolution character varying(255),
    resolution_reason text,
    resolved_by uuid,
    resolved_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT reports_reason CHECK (((reason)::text = ANY ((ARRAY['harassment'::character varying, 'spam'::character varying, 'inappropriate'::character varying, 'other'::character varying])::text[]))),
    CONSTRAINT reports_status CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'resolved'::character varying])::text[]))),
    CONSTRAINT reports_target_type CHECK (((target_type)::text = ANY ((ARRAY['discussion'::character varying, 'reply'::character varying])::text[])))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: votes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.votes (
    user_id uuid NOT NULL,
    target_type character varying(255) NOT NULL,
    target_id uuid NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT votes_target_type CHECK (((target_type)::text = ANY ((ARRAY['discussion'::character varying, 'reply'::character varying])::text[])))
);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (slug);


--
-- Name: discussions discussions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.discussions
    ADD CONSTRAINT discussions_pkey PRIMARY KEY (id);


--
-- Name: follows follows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_pkey PRIMARY KEY (user_id, discussion_id);


--
-- Name: moderation_log moderation_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.moderation_log
    ADD CONSTRAINT moderation_log_pkey PRIMARY KEY (id);


--
-- Name: replies replies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.replies
    ADD CONSTRAINT replies_pkey PRIMARY KEY (id);


--
-- Name: reports reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reports
    ADD CONSTRAINT reports_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: votes votes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.votes
    ADD CONSTRAINT votes_pkey PRIMARY KEY (user_id, target_type, target_id);


--
-- Name: discussions_author_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX discussions_author_id_inserted_at_index ON public.discussions USING btree (author_id, inserted_at);


--
-- Name: discussions_category_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX discussions_category_index ON public.discussions USING btree (category);


--
-- Name: discussions_last_activity_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX discussions_last_activity_at_index ON public.discussions USING btree (last_activity_at);


--
-- Name: discussions_slug_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX discussions_slug_index ON public.discussions USING btree (slug);


--
-- Name: follows_discussion_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX follows_discussion_id_index ON public.follows USING btree (discussion_id);


--
-- Name: moderation_log_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX moderation_log_inserted_at_index ON public.moderation_log USING btree (inserted_at);


--
-- Name: moderation_log_target_type_target_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX moderation_log_target_type_target_id_index ON public.moderation_log USING btree (target_type, target_id);


--
-- Name: replies_author_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX replies_author_id_inserted_at_index ON public.replies USING btree (author_id, inserted_at);


--
-- Name: replies_discussion_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX replies_discussion_id_inserted_at_index ON public.replies USING btree (discussion_id, inserted_at);


--
-- Name: reports_one_open_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX reports_one_open_index ON public.reports USING btree (reporter_id, target_type, target_id) WHERE ((status)::text = 'open'::text);


--
-- Name: reports_status_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_status_inserted_at_index ON public.reports USING btree (status, inserted_at);


--
-- Name: reports_target_type_target_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_target_type_target_id_index ON public.reports USING btree (target_type, target_id);


--
-- Name: discussions discussions_category_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.discussions
    ADD CONSTRAINT discussions_category_fkey FOREIGN KEY (category) REFERENCES public.categories(slug);


--
-- Name: discussions discussions_solution_reply_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.discussions
    ADD CONSTRAINT discussions_solution_reply_id_fkey FOREIGN KEY (solution_reply_id) REFERENCES public.replies(id) ON DELETE SET NULL;


--
-- Name: follows follows_discussion_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follows
    ADD CONSTRAINT follows_discussion_id_fkey FOREIGN KEY (discussion_id) REFERENCES public.discussions(id) ON DELETE CASCADE;


--
-- Name: replies replies_discussion_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.replies
    ADD CONSTRAINT replies_discussion_id_fkey FOREIGN KEY (discussion_id) REFERENCES public.discussions(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

