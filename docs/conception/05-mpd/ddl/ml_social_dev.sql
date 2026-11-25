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
-- Name: attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attachments (
    id uuid NOT NULL,
    message_id uuid NOT NULL,
    uploader_id uuid NOT NULL,
    kind character varying(255) NOT NULL,
    content_type character varying(255) NOT NULL,
    byte_size integer NOT NULL,
    width integer,
    height integer,
    filename character varying(255),
    alt_text text,
    scan character varying(255) NOT NULL,
    storage_key character varying(255),
    erased_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT attachments_kind CHECK ((((kind)::text = ANY ((ARRAY['image'::character varying, 'pdf'::character varying])::text[])) AND ((scan)::text = ANY ((ARRAY['clean'::character varying, 'unscanned'::character varying])::text[])))),
    CONSTRAINT attachments_text CHECK (((char_length(alt_text) <= 300) AND (char_length((filename)::text) <= 120)))
);


--
-- Name: blocks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.blocks (
    blocker_id uuid NOT NULL,
    blocked_id uuid NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT blocks_not_self CHECK ((blocker_id <> blocked_id))
);


--
-- Name: conversation_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversation_members (
    conversation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    last_read_at timestamp without time zone,
    joined_at timestamp without time zone DEFAULT now() NOT NULL,
    muted_until timestamp without time zone
);


--
-- Name: conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversations (
    id uuid NOT NULL,
    user_low uuid,
    user_high uuid,
    inserted_at timestamp without time zone NOT NULL,
    kind character varying(255) DEFAULT 'direct'::character varying NOT NULL,
    name character varying(255),
    owner_id uuid,
    CONSTRAINT conversations_shape CHECK (((((kind)::text = 'direct'::text) AND (user_low IS NOT NULL) AND (user_high IS NOT NULL) AND (user_low < user_high) AND (name IS NULL) AND (owner_id IS NULL)) OR (((kind)::text = 'group'::text) AND (user_low IS NULL) AND (user_high IS NULL) AND (owner_id IS NOT NULL) AND ((char_length((name)::text) >= 1) AND (char_length((name)::text) <= 60)))))
);


--
-- Name: friendships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.friendships (
    id uuid NOT NULL,
    requester_id uuid NOT NULL,
    addressee_id uuid NOT NULL,
    status character varying(255) DEFAULT 'pending'::character varying NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT friendships_not_self CHECK ((requester_id <> addressee_id)),
    CONSTRAINT friendships_status CHECK (((status)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying])::text[])))
);


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id uuid NOT NULL,
    conversation_id uuid NOT NULL,
    sender_id uuid NOT NULL,
    body text,
    inserted_at timestamp without time zone NOT NULL,
    removed_at timestamp without time zone,
    removed_by uuid,
    kind character varying(255) DEFAULT 'text'::character varying NOT NULL,
    system jsonb,
    CONSTRAINT messages_body_length CHECK (((body IS NULL) OR ((char_length(body) >= 1) AND (char_length(body) <= 2000)))),
    CONSTRAINT messages_kind CHECK (((((kind)::text = 'text'::text) AND (system IS NULL)) OR (((kind)::text = 'system'::text) AND (system IS NOT NULL) AND (body IS NULL))))
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
    message_body text,
    message_sender_id uuid,
    message_sent_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    status character varying(255) DEFAULT 'open'::character varying NOT NULL,
    resolution character varying(255),
    resolution_reason text,
    resolved_by uuid,
    resolved_at timestamp without time zone,
    sanction_id uuid,
    message_attachment_id uuid,
    CONSTRAINT reports_reason CHECK (((reason)::text = ANY ((ARRAY['harassment'::character varying, 'spam'::character varying, 'inappropriate'::character varying, 'other'::character varying])::text[]))),
    CONSTRAINT reports_resolution CHECK (((resolution IS NULL) OR ((resolution)::text = ANY ((ARRAY['dismiss'::character varying, 'remove_message'::character varying, 'warn'::character varying, 'restrict'::character varying])::text[])))),
    CONSTRAINT reports_status CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'resolved'::character varying])::text[]))),
    CONSTRAINT reports_target_type CHECK (((target_type)::text = ANY ((ARRAY['user'::character varying, 'message'::character varying])::text[])))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.settings (
    user_id uuid NOT NULL,
    show_online boolean DEFAULT true NOT NULL,
    read_receipts boolean DEFAULT true NOT NULL,
    friend_requests character varying(255) DEFAULT 'everyone'::character varying NOT NULL,
    group_adds character varying(255) DEFAULT 'friends'::character varying NOT NULL,
    lobby_invites character varying(255) DEFAULT 'friends'::character varying NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT settings_values CHECK ((((friend_requests)::text = ANY ((ARRAY['everyone'::character varying, 'friends_of_friends'::character varying, 'nobody'::character varying])::text[])) AND ((group_adds)::text = ANY ((ARRAY['friends'::character varying, 'nobody'::character varying])::text[])) AND ((lobby_invites)::text = ANY ((ARRAY['friends'::character varying, 'nobody'::character varying])::text[]))))
);


--
-- Name: attachments attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_pkey PRIMARY KEY (id);


--
-- Name: blocks blocks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.blocks
    ADD CONSTRAINT blocks_pkey PRIMARY KEY (blocker_id, blocked_id);


--
-- Name: conversation_members conversation_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_members
    ADD CONSTRAINT conversation_members_pkey PRIMARY KEY (conversation_id, user_id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: friendships friendships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.friendships
    ADD CONSTRAINT friendships_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


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
-- Name: settings settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.settings
    ADD CONSTRAINT settings_pkey PRIMARY KEY (user_id);


--
-- Name: attachments_message_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX attachments_message_id_index ON public.attachments USING btree (message_id);


--
-- Name: attachments_storage_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX attachments_storage_key_index ON public.attachments USING btree (storage_key);


--
-- Name: attachments_uploader_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX attachments_uploader_id_index ON public.attachments USING btree (uploader_id);


--
-- Name: blocks_blocked_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX blocks_blocked_id_index ON public.blocks USING btree (blocked_id);


--
-- Name: conversation_members_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX conversation_members_user_id_index ON public.conversation_members USING btree (user_id);


--
-- Name: conversations_user_low_user_high_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX conversations_user_low_user_high_index ON public.conversations USING btree (user_low, user_high);


--
-- Name: friendships_addressee_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX friendships_addressee_id_status_index ON public.friendships USING btree (addressee_id, status);


--
-- Name: friendships_pair_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX friendships_pair_index ON public.friendships USING btree (LEAST(requester_id, addressee_id), GREATEST(requester_id, addressee_id));


--
-- Name: friendships_requester_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX friendships_requester_id_status_index ON public.friendships USING btree (requester_id, status);


--
-- Name: messages_conversation_id_inserted_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX messages_conversation_id_inserted_at_id_index ON public.messages USING btree (conversation_id, inserted_at, id);


--
-- Name: reports_status_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_status_inserted_at_index ON public.reports USING btree (status, inserted_at);


--
-- Name: reports_target_type_target_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reports_target_type_target_id_index ON public.reports USING btree (target_type, target_id);


--
-- Name: attachments attachments_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.messages(id) ON DELETE CASCADE;


--
-- Name: conversation_members conversation_members_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversation_members
    ADD CONSTRAINT conversation_members_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- Name: messages messages_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.conversations(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

