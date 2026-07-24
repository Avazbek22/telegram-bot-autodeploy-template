# Security Policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature when it is enabled
for the repository created from this template. If it is not enabled, contact the
repository owner through a private channel they publish. Do not open a public
issue containing a token, server address, or exploit details.

This project is maintained by volunteers and does not promise a response or
resolution deadline. Reports that include affected versions, impact, and a
minimal reproduction are especially helpful.

## Operator responsibilities

- Keep `.env` mode `0600` and never commit it.
- Rotate a token immediately if it may have been exposed.
- Apply Ubuntu and Docker security updates.
- Restrict SSH and sudo access to the VPS.
- Review dependency and template updates before merging them to `main`.
- Remember that anyone who can push to `main` can cause code to run on the VPS.
