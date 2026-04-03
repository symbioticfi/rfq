import js from "@eslint/js";
import typescriptEslint from "@typescript-eslint/eslint-plugin";
import typescriptParser from "@typescript-eslint/parser";
import { defineConfig, globalIgnores } from "eslint/config";

export default defineConfig(globalIgnores(["build/", "coverage/", ".react-router/"]), js.configs.recommended, {
  files: ["**/*.ts", "**/*.tsx"],
  plugins: {
    "@typescript-eslint": typescriptEslint,
  },
  languageOptions: {
    parser: typescriptParser,
    parserOptions: {
      projectService: true,
      tsconfigRootDir: import.meta.dirname,
    },
  },
  rules: {
    ...typescriptEslint.configs.recommended.rules,
    "no-undef": "off",
    "@typescript-eslint/no-deprecated": "warn",
  },
});
