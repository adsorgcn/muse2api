# AGENTS.md

This repository is muse2api: the chat, image and video generation of the muse.ai web app, served as an OpenAI-compatible API from the user's own server, with a pool of the user's own muse.ai accounts. MIT, based on MUSE2API.

## The user wants it deployed

Follow `install.md` in this repository step by step. It is an iLang engineering book written for any agent that can run shell commands:

- it deploys only through `install.sh` on the user's own Ubuntu or Debian server;
- the user types the root password and logs in to muse.ai himself; you never ask for either in chat;
- accounts are imported one by one and each is tested;
- the result is checked by the RUBRIC at the end of the book.
- the user ticks on a choice card what to install (muse2api, a domain with https, the New API relay station) and the relay settings; you never choose for the user.

Raw link for agents: https://raw.githubusercontent.com/adsorgcn/muse2api/main/install.md

## You are changing this repository

- Files of the original project (`app.py`, `engine.py`, `admin.html`, `README.md`, `docker-compose.yml`, `Dockerfile`, `tools/`, `extension/` and the rest) stay identical to upstream, so upstream releases merge without conflicts. Do not edit them here.
- Files added by this distribution: `install.sh`, `install.md`, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.github/README.md`.
- After editing `install.sh`, run `bash -n install.sh`. After editing `install.md`, run the iLang grammar validator in strict mode (`ilang_grammar_validator.py --lint install.md --strict`, from github.com/ilang-ai/ilang-spec); it must report 0 errors and 0 warnings.
- An upstream release is merged only after `install.sh` has run on a test server: fresh install, re-run as upgrade, and the RUBRIC of `install.md`.
- Never commit `.env`, `data/`, cookies, API keys or passwords.
- This distribution has no DOI, no CITATION.cff and no Zenodo archive. Do not add them.
