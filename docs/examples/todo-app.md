# Example: Full-Stack Todo App

This example shows how to use Ensemble to build a Todo application with two parallel workers.

## The Goal

Build a complete Todo app with:
- A Flask REST API backend with SQLAlchemy
- A React frontend with TypeScript
- Both built simultaneously by separate workers

## Step 1: Start Ensemble

In Claude Code, run `/orchestrate` and describe your goal:

> "Build a full-stack Todo application. I want a Flask REST API backend with SQLAlchemy and a React frontend with TypeScript."

## Step 2: Ensemble Breaks It Down

Ensemble will identify two independent workstreams:
- **Worker 1**: Backend (Flask + SQLAlchemy) -- handles data models, REST endpoints, and tests
- **Worker 2**: Frontend (React + TypeScript) -- handles UI components, state management, and tests

## Step 3: Workers Are Spawned

Behind the scenes, Ensemble runs:

```bash
bash spawn-worker.sh --name "backend" \
  --project ~/projects/todo-backend \
  --task "Build a Flask REST API for a Todo application. Use SQLAlchemy for the database with a SQLite backend. Create endpoints: GET /api/todos, POST /api/todos, PUT /api/todos/:id, DELETE /api/todos/:id. Each todo has: id, title, description, completed (boolean), created_at. Include input validation, error handling, and pytest tests." \
  --budget 10

bash spawn-worker.sh --name "frontend" \
  --project ~/projects/todo-frontend \
  --task "Build a React frontend for a Todo application using TypeScript. Connect to a REST API at http://localhost:5000/api/todos. Create components for: TodoList, TodoItem, AddTodoForm. Support creating, completing, and deleting todos. Use modern React patterns (hooks, functional components). Include unit tests with Jest." \
  --budget 10
```

Each worker gets its own tmux window inside the `ensemble` session.

## Step 4: Monitor Progress

Attach to the tmux session to see the live dashboard:

```bash
tmux attach -t ensemble
```

The `status` window shows both workers progressing through phases:

```
ENSEMBLE WORKER DASHBOARD  2026-03-03 14:30:00

┌─────────────────────────────────────────────────────────────────────────────────────────┐
│ WORKER          │ PROJECT          │ PHASE        │ PROGRESS     │  PCT │ STATUS     │ HEARTBEAT       │
├─────────────────┼──────────────────┼──────────────┼──────────────┼──────┼────────────┼─────────────────┤
│ worker-backend  │ todo-backend     │ implementing │ ██████░░░░░░ │  60% │ > active   │ 12s ago         │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│ worker-frontend │ todo-frontend    │ planning     │ ███░░░░░░░░░ │  30% │ > active   │ 8s ago          │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

Switch between tmux windows to see each worker's live Claude Code output:
- `Ctrl+B, 1` -- dashboard
- `Ctrl+B, 2` -- backend worker
- `Ctrl+B, 3` -- frontend worker

## Step 5: Cross-Worker Communication

When the backend API schema is ready, Ensemble sends it to the frontend worker so it can align its API calls:

```bash
bash send-message.sh worker-backend worker-frontend "API schema ready" \
  '{"endpoints":[{"method":"GET","path":"/api/todos"},{"method":"POST","path":"/api/todos"},{"method":"PUT","path":"/api/todos/:id"},{"method":"DELETE","path":"/api/todos/:id"}],"port":5000}'
```

The frontend worker receives this message and adjusts its API integration code accordingly.

## Step 6: Results

Both workers complete independently. The dashboard updates to show completion:

```
│ worker-backend  │ todo-backend     │ done         │ ████████████ │ 100% │ ✓ completed │ 2m 30s ago     │
│ worker-frontend │ todo-frontend    │ done         │ ████████████ │ 100% │ ✓ completed │ 1m 15s ago     │
```

You get:
- **Backend**: A working Flask API with SQLAlchemy models, all CRUD endpoints, input validation, error handling, and passing pytest tests
- **Frontend**: A working React + TypeScript app with Todo components, API integration, and passing Jest tests
- **Both**: Following best practices, with clean code and test coverage

## What Happened Under the Hood

1. `spawn-worker.sh` created worker JSON files in `~/.claude/orchestrator/workers/`
2. Each worker ran `claude -p` with `--output-format stream-json` piped to a log file
3. `monitor.sh` periodically read the logs, called `parse-phase.sh` to detect phases, and updated worker JSON
4. `dashboard.sh` read the worker JSON files and rendered the terminal display
5. `send-message.sh` wrote a message file to `~/.claude/orchestrator/messages/` for cross-worker coordination
