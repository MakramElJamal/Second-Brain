"""Console entry point: run the upstream secure server with our extension.

This is the deployment's own entry point (per the upstream extension-seam
pattern). It runs the full hardened obsidian-web-mcp server — OAuth/PKCE login
gate, bearer auth, path-safety, atomic writes, audit log — and
adds our token-light search_notes / get_note tools on top.
"""

from obsidian_vault_mcp.server import serve

from .extension import SecondBrainExtension


def main() -> None:
    serve([SecondBrainExtension()])


if __name__ == "__main__":
    main()
