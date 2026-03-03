# Example: Microservices Architecture

This example shows how to use Ensemble to build three independent microservices simultaneously with three parallel workers.

## The Goal

Build a microservices backend with:
- An **auth-service** for user authentication and JWT token management
- A **user-service** for user profile CRUD operations
- A **notification-service** for email and in-app notifications

All three services are independent and can be built in parallel.

## Step 1: Start Ensemble

In Claude Code, run `/orchestrate` and describe your goal:

> "Build three microservices: an auth service with JWT authentication, a user profile service with CRUD operations, and a notification service for emails and in-app notifications. Use Node.js with Express for all three. Each should have its own test suite."

## Step 2: Ensemble Breaks It Down

Ensemble identifies three independent workstreams:
- **Worker 1**: Auth Service -- JWT login/logout, token refresh, password hashing
- **Worker 2**: User Service -- profile CRUD, avatar upload, search
- **Worker 3**: Notification Service -- email sending, in-app notifications, preference management

## Step 3: Workers Are Spawned

Behind the scenes, Ensemble runs:

```bash
bash spawn-worker.sh --name "auth-service" \
  --project ~/projects/auth-service \
  --task "Build an authentication microservice with Node.js and Express. Implement: POST /auth/register, POST /auth/login, POST /auth/logout, POST /auth/refresh-token. Use bcrypt for password hashing and JWT for tokens. Store users in SQLite via Knex.js. Include middleware for token verification. Write Mocha/Chai tests for all endpoints." \
  --budget 15

bash spawn-worker.sh --name "user-service" \
  --project ~/projects/user-service \
  --task "Build a user profile microservice with Node.js and Express. Implement: GET /users/:id, PUT /users/:id, DELETE /users/:id, GET /users/search?q=. User fields: id, email, display_name, bio, avatar_url, created_at, updated_at. Store in SQLite via Knex.js. Include input validation with Joi. Write Mocha/Chai tests." \
  --budget 15

bash spawn-worker.sh --name "notification-service" \
  --project ~/projects/notification-service \
  --task "Build a notification microservice with Node.js and Express. Implement: POST /notifications/email (send email via Nodemailer), POST /notifications/in-app (create in-app notification), GET /notifications/:user_id (list notifications), PUT /notifications/:id/read (mark as read), GET /notifications/preferences/:user_id, PUT /notifications/preferences/:user_id. Store in SQLite via Knex.js. Write Mocha/Chai tests." \
  --budget 15
```

## Step 4: Monitor Progress

Attach to the tmux session:

```bash
tmux attach -t ensemble
```

The dashboard shows all three workers progressing:

```
ENSEMBLE WORKER DASHBOARD  2026-03-03 15:00:00

┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│ WORKER                │ PROJECT              │ PHASE        │ PROGRESS     │  PCT │ STATUS     │ HEARTBEAT  │
├───────────────────────┼──────────────────────┼──────────────┼──────────────┼──────┼────────────┼────────────┤
│ worker-auth-service   │ auth-service         │ implementing │ ██████░░░░░░ │  60% │ > active   │ 5s ago     │
├──────────────────────────────────────────────────────────────────────────────────────────────┤
│ worker-user-service   │ user-service         │ implementing │ ██████░░░░░░ │  60% │ > active   │ 3s ago     │
├──────────────────────────────────────────────────────────────────────────────────────────────┤
│ worker-notification-s │ notification-service │ planning     │ ███░░░░░░░░░ │  30% │ > active   │ 8s ago     │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

Navigate between tmux windows:
- `Ctrl+B, 1` -- dashboard
- `Ctrl+B, 2` -- auth-service worker
- `Ctrl+B, 3` -- user-service worker
- `Ctrl+B, 4` -- notification-service worker

## Step 5: Cross-Worker Communication

Once the auth service defines its JWT token format, Ensemble shares it with the other services so they can implement token verification middleware:

```bash
bash send-message.sh worker-auth-service worker-user-service \
  "JWT token format defined" \
  '{"algorithm":"HS256","payload":{"sub":"user_id","email":"user_email","iat":"issued_at","exp":"expiry"},"header":"Authorization: Bearer <token>"}'

bash send-message.sh worker-auth-service worker-notification-service \
  "JWT token format defined" \
  '{"algorithm":"HS256","payload":{"sub":"user_id","email":"user_email","iat":"issued_at","exp":"expiry"},"header":"Authorization: Bearer <token>"}'
```

When the user service finishes its schema, it notifies the notification service:

```bash
bash send-message.sh worker-user-service worker-notification-service \
  "User schema ready" \
  '{"fields":["id","email","display_name"],"endpoint":"GET /users/:id"}'
```

## Step 6: Handling Issues

During the build, one worker might get stuck. The monitor handles this automatically:

1. `monitor.sh` detects that `worker-notification-s` has not produced output for 5+ minutes
2. It marks the worker as `stuck` in the dashboard
3. If the worker crashed, the monitor auto-resumes it (up to 2 retries)

You can also check manually:

```bash
# View the worker's log
tail -50 ~/.claude/orchestrator/logs/worker-notification-s.log

# Check the worker's JSON state
cat ~/.claude/orchestrator/workers/worker-notification-s.json | jq .
```

## Step 7: Results

All three workers complete. Final dashboard:

```
│ worker-auth-service   │ auth-service         │ done │ ████████████ │ 100% │ ✓ completed │ 5m ago  │
│ worker-user-service   │ user-service         │ done │ ████████████ │ 100% │ ✓ completed │ 3m ago  │
│ worker-notification-s │ notification-service │ done │ ████████████ │ 100% │ ✓ completed │ 1m ago  │
```

You get three independent, tested microservices:

- **auth-service**: JWT authentication with register, login, logout, and token refresh endpoints. Password hashing with bcrypt. Token verification middleware.
- **user-service**: User profile CRUD with search. Input validation with Joi. Proper error handling.
- **notification-service**: Email sending via Nodemailer. In-app notification storage and retrieval. User notification preferences.

Each service has its own test suite, database schema, and can be deployed independently.

## Cost Summary

The dashboard's summary panel shows the total spend across all workers:

```
Total runtime:         0h 18m 42s
Total budget spent:    $12.35

Active    workers:     0 workers running
Completed workers:     3 workers (finished)
```

All three services were built in parallel in under 20 minutes, compared to the 45-60 minutes it would take sequentially.
