CREATE TABLE "rfq_backend"."discounts" (
	"discount_id" varchar(66) PRIMARY KEY NOT NULL,
	"chain_id" integer NOT NULL,
	"vault" varchar(42) NOT NULL,
	"token_to_redeem" varchar(42) NOT NULL,
	"discount_ppm" text NOT NULL,
	"signer" varchar(42) NOT NULL,
	"protocol" varchar(42) NOT NULL,
	"nonce" varchar(66) NOT NULL,
	"deadline" bigint NOT NULL,
	"signer_signature" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX "rfq_discounts_live_pair_idx" ON "rfq_backend"."discounts" USING btree ("chain_id","vault","token_to_redeem");--> statement-breakpoint
CREATE INDEX "rfq_discounts_pair_idx" ON "rfq_backend"."discounts" USING btree ("chain_id","vault","token_to_redeem");--> statement-breakpoint
