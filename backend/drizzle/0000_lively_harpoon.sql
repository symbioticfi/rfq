CREATE SCHEMA "rfq_backend";
--> statement-breakpoint
CREATE SCHEMA "rfq_indexer";
--> statement-breakpoint
CREATE TYPE "public"."rfq_order_internal_status" AS ENUM('hard_auction', 'winner_selected', 'tx_submitted', 'filled', 'expired', 'failed');--> statement-breakpoint
CREATE TYPE "public"."rfq_order_public_status" AS ENUM('open', 'expired', 'error', 'cancelled', 'filled', 'unverified', 'insufficient-funds');--> statement-breakpoint
CREATE TYPE "public"."rfq_quote_phase" AS ENUM('preview', 'executable');--> statement-breakpoint
CREATE TYPE "public"."rfq_solver_quote_status" AS ENUM('quoted', 'no_quote', 'timeout', 'error', 'cooldown');--> statement-breakpoint
CREATE TABLE "rfq_backend"."order_outputs" (
	"order_id" uuid NOT NULL,
	"output_index" integer NOT NULL,
	"token" varchar(42) NOT NULL,
	"recipient" varchar(42) NOT NULL,
	"amount" text NOT NULL,
	CONSTRAINT "order_outputs_order_id_output_index_pk" PRIMARY KEY("order_id","output_index")
);
--> statement-breakpoint
CREATE TABLE "rfq_backend"."order_status_history" (
	"id" uuid PRIMARY KEY NOT NULL,
	"order_id" uuid NOT NULL,
	"public_status" "rfq_order_public_status" NOT NULL,
	"internal_status" "rfq_order_internal_status" NOT NULL,
	"reason" text,
	"created_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "rfq_backend"."orders" (
	"id" uuid PRIMARY KEY NOT NULL,
	"request_id" uuid NOT NULL,
	"quote_id" uuid NOT NULL,
	"order_hash" varchar(66) NOT NULL,
	"swapper" varchar(42) NOT NULL,
	"filler" varchar(42) NOT NULL,
	"token_in" varchar(42) NOT NULL,
	"amount_in" text NOT NULL,
	"nonce" varchar(66) NOT NULL,
	"deadline" bigint NOT NULL,
	"encoded_order" text NOT NULL,
	"protocol_signature" text NOT NULL,
	"swapper_signature" text NOT NULL,
	"public_status" "rfq_order_public_status" NOT NULL,
	"internal_status" "rfq_order_internal_status" NOT NULL,
	"tx_hash" varchar(66),
	"created_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone NOT NULL,
	CONSTRAINT "orders_order_hash_unique" UNIQUE("order_hash")
);
--> statement-breakpoint
CREATE TABLE "rfq_backend"."quote_requests" (
	"id" uuid PRIMARY KEY NOT NULL,
	"request_id" uuid NOT NULL,
	"quote_id" uuid NOT NULL,
	"phase" "rfq_quote_phase" NOT NULL,
	"request_payload" jsonb NOT NULL,
	"permit_data" jsonb NOT NULL,
	"outputs" jsonb NOT NULL,
	"best_amount_out" text,
	"best_filler" varchar(42),
	"selected_solver_id" uuid,
	"expires_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	CONSTRAINT "quote_requests_request_id_unique" UNIQUE("request_id"),
	CONSTRAINT "quote_requests_quote_id_unique" UNIQUE("quote_id")
);
--> statement-breakpoint
CREATE TABLE "rfq_indexer"."reactor_fill_output" (
	"fill_id" text NOT NULL,
	"output_index" integer NOT NULL,
	"token" varchar(42) NOT NULL,
	"recipient" varchar(42) NOT NULL,
	"amount" text NOT NULL,
	CONSTRAINT "reactor_fill_output_fill_id_output_index_pk" PRIMARY KEY("fill_id","output_index")
);
--> statement-breakpoint
CREATE TABLE "rfq_indexer"."reactor_fill" (
	"id" text PRIMARY KEY NOT NULL,
	"tx_hash" varchar(66) NOT NULL,
	"order_hash" varchar(66) NOT NULL
);
--> statement-breakpoint
CREATE TABLE "rfq_indexer"."instant_redemption_adapter_filler_authorization" (
	"id" text PRIMARY KEY NOT NULL,
	"chain_id" integer NOT NULL,
	"market_maker" varchar(42) NOT NULL,
	"filler" varchar(42) NOT NULL,
	"status" boolean NOT NULL,
	"tx_hash" varchar(66) NOT NULL,
	"block_number" bigint NOT NULL,
	"log_index" integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE "rfq_backend"."solver_quotes" (
	"id" uuid PRIMARY KEY NOT NULL,
	"quote_request_id" uuid NOT NULL,
	"solver_id" uuid NOT NULL,
	"phase" "rfq_quote_phase" NOT NULL,
	"status" "rfq_solver_quote_status" NOT NULL,
	"latency_ms" integer NOT NULL,
	"amount_out" text,
	"filler" varchar(42),
	"response_payload" jsonb,
	"error_message" text,
	"created_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "rfq_backend"."solvers" (
	"id" uuid PRIMARY KEY NOT NULL,
	"chain_id" integer NOT NULL,
	"name" text NOT NULL,
	"endpoint_url" text NOT NULL,
	"notify_url" text,
	"filler" varchar(42) NOT NULL,
	"enabled" boolean DEFAULT true NOT NULL,
	"cooldown_until" timestamp with time zone,
	"metadata" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE INDEX "rfq_order_outputs_order_idx" ON "rfq_backend"."order_outputs" USING btree ("order_id");--> statement-breakpoint
CREATE INDEX "rfq_order_status_history_order_idx" ON "rfq_backend"."order_status_history" USING btree ("order_id");--> statement-breakpoint
CREATE INDEX "rfq_orders_quote_idx" ON "rfq_backend"."orders" USING btree ("quote_id");--> statement-breakpoint
CREATE INDEX "rfq_orders_swapper_idx" ON "rfq_backend"."orders" USING btree ("swapper");--> statement-breakpoint
CREATE INDEX "rfq_orders_filler_idx" ON "rfq_backend"."orders" USING btree ("filler");--> statement-breakpoint
CREATE INDEX "rfq_orders_public_status_idx" ON "rfq_backend"."orders" USING btree ("public_status");--> statement-breakpoint
CREATE INDEX "rfq_quote_requests_expires_idx" ON "rfq_backend"."quote_requests" USING btree ("expires_at");--> statement-breakpoint
CREATE INDEX "rfq_indexer_reactor_fill_output_fill_idx" ON "rfq_indexer"."reactor_fill_output" USING btree ("fill_id");--> statement-breakpoint
CREATE INDEX "rfq_indexer_reactor_fill_order_hash_idx" ON "rfq_indexer"."reactor_fill" USING btree ("order_hash");--> statement-breakpoint
CREATE INDEX "rfq_indexer_adapter_filler_authorization_filler_idx" ON "rfq_indexer"."instant_redemption_adapter_filler_authorization" USING btree ("chain_id","filler");--> statement-breakpoint
CREATE INDEX "rfq_indexer_adapter_filler_authorization_market_maker_idx" ON "rfq_indexer"."instant_redemption_adapter_filler_authorization" USING btree ("market_maker");--> statement-breakpoint
CREATE INDEX "rfq_solver_quotes_quote_idx" ON "rfq_backend"."solver_quotes" USING btree ("quote_request_id");--> statement-breakpoint
CREATE INDEX "rfq_solver_quotes_solver_idx" ON "rfq_backend"."solver_quotes" USING btree ("solver_id");--> statement-breakpoint
CREATE INDEX "rfq_solvers_chain_idx" ON "rfq_backend"."solvers" USING btree ("chain_id");
