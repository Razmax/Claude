# CI setup: deploying from GitHub Actions

Three workflows, using JWT authentication so no browser login and no long-lived
refresh token is ever stored in the repository.

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `pr-validate.yml` | Pull request touching `force-app/**` | Compiles and runs all local tests against QA. Changes nothing |
| `deploy-qa.yml` | Push to `main` (or manual) | Deploys to QA and runs tests |
| `deploy-prod.yml` | Manual only | Validates against production, waits for a human approval, then quick-deploys |

## Before you start: the branch assumption

`deploy-qa.yml` triggers on pushes to **`main`**. This repository does not have a
`main` branch yet — the only branch is the feature branch this work landed on. Either
create `main` and make it the default, or change the `branches:` list in
`deploy-qa.yml` to whatever you settle on.

---

## 1. Create the integration user

In **each** org (QA and production), pick or create the user that CI will deploy as.
A dedicated integration user is strongly preferred over a person's account — a
deployment shouldn't break because someone left.

It needs the **Modify All Data** and **Modify Metadata Through Metadata API Functions**
permissions, or simply the System Administrator profile.

## 2. Generate a key pair per org

```bash
./scripts/ci/generate-jwt-cert.sh qa
./scripts/ci/generate-jwt-cert.sh prod
```

Separate key pairs per org, deliberately: revoking QA access should never be able to
touch production. Output lands in `.jwt-keys/`, which is gitignored.

## 3. Create a connected app in each org

Setup → App Manager → **New Connected App** (choose the full connected app option, not
an external client app).

- **Enable OAuth Settings**: yes
- **Callback URL**: `http://localhost:1717/OauthRedirect` (unused by JWT, but required)
- **Use digital signatures**: yes — upload `.jwt-keys/<org>-server.crt`
- **Selected OAuth Scopes**:
  - Manage user data via APIs (`api`)
  - Perform requests at any time (`refresh_token, offline_access`)
- Save, then **Manage** → **Edit Policies**:
  - **Permitted Users**: *Admin approved users are pre-authorized*
  - **IP Relaxation**: *Relax IP restrictions*
- Back on Manage, under **Profiles** or **Permission Sets**, add the integration user's
  profile or a permission set they hold. **JWT login fails until you do this.**

Then copy the **Consumer Key** from the app's API section.

> Connected app changes can take a few minutes to propagate. A `JWT_AUTH_ERROR` right
> after setup is usually just impatience.

## 4. Set the GitHub secrets

Repository → Settings → Secrets and variables → Actions.

| Secret | QA value | Production value |
| --- | --- | --- |
| `SF_QA_CLIENT_ID` / `SF_PROD_CLIENT_ID` | Consumer Key of the QA connected app | Consumer Key of the prod connected app |
| `SF_QA_USERNAME` / `SF_PROD_USERNAME` | Integration user's username | Integration user's username |
| `SF_QA_JWT_KEY` / `SF_PROD_JWT_KEY` | base64 of `qa-server.key` | base64 of `prod-server.key` |
| `SF_QA_INSTANCE_URL` / `SF_PROD_INSTANCE_URL` | `https://test.salesforce.com` | `https://login.salesforce.com` |

The key must be base64-encoded so the newlines survive the secret store:

```bash
gh secret set SF_QA_JWT_KEY   < <(base64 -w0 .jwt-keys/qa-server.key)
gh secret set SF_PROD_JWT_KEY < <(base64 -w0 .jwt-keys/prod-server.key)
```

On macOS use `base64 -i .jwt-keys/qa-server.key` instead.

A sandbox username usually carries the sandbox suffix — `jane@example.com.qa`, not
`jane@example.com`. Getting this wrong is the most common cause of a failed JWT login.

Once a workflow run has authenticated successfully, delete the local keys:
`rm -rf .jwt-keys`.

## 5. Create the environments and gate production

Repository → Settings → **Environments**.

- **`qa`** — no protection needed.
- **`production`** — add **Required reviewers**. This is the whole point of the
  production workflow's two-job split: validation runs and reports its test results,
  and only then does a named human get asked to approve the actual deploy.

Without reviewers on the `production` environment, the quick deploy proceeds
automatically and you have lost the gate.

## 6. First run

Do this in order:

1. Open a PR with any change under `force-app/`. Watch `pr-validate.yml`.
2. **Expect it to fail the first time.** This project has never been compiled against
   a real org. Read the errors, fix, push again. Repeat until green.
3. Merge. Confirm `deploy-qa.yml` deploys cleanly.
4. Exercise the routing engine in QA — create a case, watch it route, accept it,
   complete it. See `docs/DEPLOYMENT.md` for the post-deploy configuration steps.
5. Only then run **Deploy to Production** manually.

---

## How the production workflow behaves

Stage one runs `sf project deploy validate` against production. Nothing is written to
the org; Salesforce compiles everything and runs the test level you chose, then returns
a job id. That id is a *validated deployment*, and Salesforce will hold it for 10 days.

Stage two waits for approval, then runs `sf project deploy quick --job-id <id>`. Because
the payload is already validated, it applies in seconds without re-running the suite —
which matters, because a full production deploy with `RunLocalTests` can take a long
time, and you do not want that window sitting between approval and completion.

If you approve more than 10 days after validating, the quick deploy fails. Re-run the
workflow.

## Post-deploy configuration is not in the pipeline

Deployments carry metadata, not data. These remain manual per org, once:

- Creating the `Service_Queue__c` records (`scripts/apex/create_sample_queues.apex`).
- Agent records, capacities, skills and queue memberships.
- Scheduling the heartbeat: `RoutingScheduler.scheduleEveryQuarterHour();`.
- Assigning the permission sets.

`Service_Routing_Setting__mdt`, presence statuses and routing rules **are** custom
metadata, so those deploy with the code — which also means a deploy will overwrite org
edits to records of the same developer name. If teams tune routing rules directly in
production, either pull those changes back into the repo, or stop deploying
`customMetadata/` and manage it in the org only.

## Troubleshooting

| Error | Cause |
| --- | --- |
| `JWT_AUTH_ERROR ... user hasn't approved this consumer` | The integration user's profile or permission set is not on the connected app's pre-authorized list (step 3) |
| `JWT_AUTH_ERROR ... invalid_grant` | Wrong username (sandbox suffix?), wrong Consumer Key, or the certificate on the app does not match the key in the secret |
| `The decoded JWT key is not a PEM private key` | The secret was set from the `.crt` instead of the `.key`, or base64 wrapping mangled it — re-encode with `base64 -w0` |
| `INVALID_CROSS_REFERENCE_KEY` on custom metadata | A routing rule references a queue Developer Name that does not exist yet in that org — run the queue script first |
| Deploy fails on coverage | Production requires 75% org-wide coverage. Check the uploaded coverage artifact to see which class is short |
