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
-- Name: lobbies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lobbies (
    id uuid NOT NULL,
    host_id uuid NOT NULL,
    title character varying(255) NOT NULL,
    visibility character varying(255) NOT NULL,
    requires_approval boolean DEFAULT false NOT NULL,
    max_players integer NOT NULL,
    starts_at timestamp without time zone,
    status character varying(255) DEFAULT 'waiting'::character varying NOT NULL,
    current_match_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT lobbies_capacity CHECK (((max_players >= 2) AND (max_players <= 4))),
    CONSTRAINT lobbies_status CHECK (((status)::text = ANY ((ARRAY['waiting'::character varying, 'playing'::character varying, 'closed'::character varying])::text[]))),
    CONSTRAINT lobbies_title CHECK (((char_length((title)::text) >= 3) AND (char_length((title)::text) <= 60))),
    CONSTRAINT lobbies_visibility CHECK (((visibility)::text = ANY ((ARRAY['open'::character varying, 'private'::character varying])::text[])))
);


--
-- Name: lobby_invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lobby_invites (
    id uuid NOT NULL,
    lobby_id uuid NOT NULL,
    inviter_id uuid NOT NULL,
    invitee_id uuid NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT lobby_invites_not_self CHECK ((inviter_id <> invitee_id)),
    CONSTRAINT lobby_invites_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying, 'declined'::character varying, 'revoked'::character varying])::text[])))
);


--
-- Name: lobby_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lobby_links (
    id uuid NOT NULL,
    lobby_id uuid NOT NULL,
    created_by uuid NOT NULL,
    token_hash bytea NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    max_uses integer NOT NULL,
    uses integer DEFAULT 0 NOT NULL,
    revoked_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT lobby_links_uses CHECK ((((max_uses >= 1) AND (max_uses <= 20)) AND ((uses >= 0) AND (uses <= max_uses))))
);


--
-- Name: lobby_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lobby_members (
    lobby_id uuid NOT NULL,
    user_id uuid NOT NULL,
    status character varying(255) NOT NULL,
    ready boolean DEFAULT false NOT NULL,
    connection character varying(255) DEFAULT 'online'::character varying NOT NULL,
    last_seen_at timestamp without time zone NOT NULL,
    joined_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT lobby_members_connection CHECK (((connection)::text = ANY ((ARRAY['online'::character varying, 'disconnected'::character varying, 'absent'::character varying])::text[]))),
    CONSTRAINT lobby_members_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'active'::character varying, 'left'::character varying, 'kicked'::character varying, 'declined'::character varying])::text[])))
);


--
-- Name: lobby_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lobby_messages (
    id uuid NOT NULL,
    lobby_id uuid NOT NULL,
    user_id uuid NOT NULL,
    body text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT lobby_messages_body CHECK (((char_length(body) >= 1) AND (char_length(body) <= 500)))
);


--
-- Name: match_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.match_events (
    match_id uuid NOT NULL,
    seq integer NOT NULL,
    type character varying(255) NOT NULL,
    user_id uuid,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT match_events_seq CHECK ((seq >= 1))
);


--
-- Name: match_rewards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.match_rewards (
    id uuid NOT NULL,
    match_id uuid NOT NULL,
    user_id uuid NOT NULL,
    amount integer NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    next_attempt_at timestamp without time zone NOT NULL,
    last_error character varying(255),
    awarded_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT match_rewards_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'awarded'::character varying, 'failed'::character varying])::text[])))
);


--
-- Name: matches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.matches (
    id uuid NOT NULL,
    lobby_id uuid NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    last_seq integer DEFAULT 0 NOT NULL,
    finished_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT matches_status CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'won'::character varying, 'lost'::character varying, 'aborted'::character varying])::text[])))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: lobbies lobbies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lobbies
    ADD CONSTRAINT lobbies_pkey PRIMARY KEY (id);


--
-- Name: lobby_invites lobby_invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lobby_invites
    ADD CONSTRAINT lobby_invites_pkey PRIMARY KEY (id);


--
-- Name: lobby_links lobby_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lobby_links
    ADD CONSTRAINT lobby_links_pkey PRIMARY KEY (id);


--
-- Name: lobby_members lobby_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lobby_members
    ADD CONSTRAINT lobby_members_pkey PRIMARY KEY (lobby_id, user_id);


--
-- Name: lobby_messages lobby_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lobby_messages
    ADD CONSTRAINT lobby_messages_pkey PRIMARY KEY (id);


--
-- Name: match_events match_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.match_events
    ADD CONSTRAINT match_events_pkey PRIMARY KEY (match_id, seq);


--
-- Name: match_rewards match_rewards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.match_rewards
    ADD CONSTRAINT match_rewards_pkey PRIMARY KEY (id);


--
-- Name: matches matches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.matches
    ADD CONSTRAINT matches_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: lobbies_host_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lobbies_host_id_status_index ON public.lobbies USING btree (host_id, status);


--
-- Name: lobbies_visibility_status_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lobbies_visibility_status_inserted_at_index ON public.lobbies USING btree (visibility, status, inserted_at);


--
-- Name: lobby_invites_invitee_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lobby_invites_invitee_id_status_index ON public.lobby_invites USING btree (invitee_id, status);


--
-- Name: lobby_invites_lobby_id_invitee_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX lobby_invites_lobby_id_invitee_id_index ON public.lobby_invites USING btree (lobby_id, invitee_id);


--
-- Name: lobby_links_lobby_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lobby_links_lobby_id_index ON public.lobby_links USING btree (lobby_id);


--
-- Name: lobby_links_token_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX lobby_links_token_hash_index ON public.lobby_links USING btree (token_hash);


--
-- Name: lobby_members_status_connection_last_seen_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lobby_members_status_connection_last_seen_at_index ON public.lobby_members USING btree (status, connection, last_seen_at);


--
-- Name: lobby_members_user_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lobby_members_user_id_status_index ON public.lobby_members USING btree (user_id, status);


--
-- Name: lobby_messages_lobby_id_inserted_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lobby_messages_lobby_id_inserted_at_id_index ON public.lobby_messages USING btree (lobby_id, inserted_at, id);


--
-- Name: lobby_messages_lobby_id_user_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lobby_messages_lobby_id_user_id_inserted_at_index ON public.lobby_messages USING btree (lobby_id, user_id, inserted_at);


--
-- Name: match_rewards_match_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX match_rewards_match_id_user_id_index ON public.match_rewards USING btree (match_id, user_id);


--
-- Name: match_rewards_status_next_attempt_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX match_rewards_status_next_attempt_at_index ON public.match_rewards USING btree (status, next_attempt_at);


--
-- Name: matches_lobby_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX matches_lobby_id_inserted_at_index ON public.matches USING btree (lobby_id, inserted_at);


--
-- Name: matches_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX matches_status_index ON public.matches USING btree (status);


--
-- Name: lobby_invites lobby_invites_lobby_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lobby_invites
    ADD CONSTRAINT lobby_invites_lobby_id_fkey FOREIGN KEY (lobby_id) REFERENCES public.lobbies(id) ON DELETE CASCADE;


--
-- Name: lobby_links lobby_links_lobby_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lobby_links
    ADD CONSTRAINT lobby_links_lobby_id_fkey FOREIGN KEY (lobby_id) REFERENCES public.lobbies(id) ON DELETE CASCADE;


--
-- Name: lobby_members lobby_members_lobby_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lobby_members
    ADD CONSTRAINT lobby_members_lobby_id_fkey FOREIGN KEY (lobby_id) REFERENCES public.lobbies(id) ON DELETE CASCADE;


--
-- Name: lobby_messages lobby_messages_lobby_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lobby_messages
    ADD CONSTRAINT lobby_messages_lobby_id_fkey FOREIGN KEY (lobby_id) REFERENCES public.lobbies(id) ON DELETE CASCADE;


--
-- Name: match_events match_events_match_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.match_events
    ADD CONSTRAINT match_events_match_id_fkey FOREIGN KEY (match_id) REFERENCES public.matches(id) ON DELETE CASCADE;


--
-- Name: match_rewards match_rewards_match_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.match_rewards
    ADD CONSTRAINT match_rewards_match_id_fkey FOREIGN KEY (match_id) REFERENCES public.matches(id) ON DELETE CASCADE;


--
-- Name: matches matches_lobby_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.matches
    ADD CONSTRAINT matches_lobby_id_fkey FOREIGN KEY (lobby_id) REFERENCES public.lobbies(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

