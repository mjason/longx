// The thread's goal (Plugs.Goal), above the thread: the objective, its status, the
// budget spent and the time; pause / resume / clear, and a dialog that sets
// or edits the objective and the token budget (also opened by /goal).
import { Pause, Play, Pencil, Target, X } from "lucide-react";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import { toast } from "sonner";
import type { ThreadGoal } from "@/core/chat/thread";
import { formatElapsed, formatTokens } from "@/core/format";
import { useGoalActions } from "@/core/projects";
import { Badge } from "@/ui/components/ui/badge";
import { Button } from "@/ui/components/ui/button";
import {
  Dialog,
  DialogBody,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/ui/components/ui/dialog";
import { Input } from "@/ui/components/ui/input";
import { Label } from "@/ui/components/ui/label";
import { Textarea } from "@/ui/components/ui/textarea";
import { t } from "@/ui/strings";

type GoalContext = {
  open: () => void;
  goal: ThreadGoal | null;
  threadId: string | undefined;
  actions: Actions;
};
const GoalDialogContext = createContext<GoalContext | null>(null);

/** opens the goal dialog from anywhere under GoalProvider (the /goal command) */
export function useGoalDialog() {
  return useContext(GoalDialogContext);
}

function fail(error: unknown) {
  toast.error(error instanceof Error ? error.message : String(error));
}

/**
 * Holds the goal dialog for the thread on screen; `GoalBar` (in the chat
 * area) shows the goal when the thread has one.
 */
export function GoalProvider({
  threadId,
  goal,
  children,
}: {
  threadId: string | undefined;
  goal: ThreadGoal | null;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const actions = useGoalActions(threadId);
  const show = useCallback(() => {
    if (!threadId) {
      toast.info(t.commands.needsThread);
      return;
    }
    setOpen(true);
  }, [threadId]);
  return (
    <GoalDialogContext.Provider value={{ open: show, goal, threadId, actions }}>
      {children}
      <GoalDialog
        open={open}
        onOpenChange={setOpen}
        goal={goal}
        actions={actions}
      />
    </GoalDialogContext.Provider>
  );
}

type Actions = ReturnType<typeof useGoalActions>;

/** The thread's goal above the chat; nothing when there is none. */
export function GoalBar() {
  const ctx = useGoalDialog();
  if (!ctx || !ctx.goal || !ctx.threadId) return null;
  return (
    <GoalBarView goal={ctx.goal} onEdit={ctx.open} actions={ctx.actions} />
  );
}

function GoalBarView({
  goal,
  onEdit,
  actions,
}: {
  goal: ThreadGoal;
  onEdit: () => void;
  actions: Actions;
}) {
  const active = goal.status === "active";
  const done = goal.status === "complete";
  const set = (status: "active" | "paused") =>
    actions.set.mutate({ status }, { onError: fail });
  return (
    <div className="border-b px-3 py-2" data-testid="goal-bar">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
        <Target
          className={`size-4 shrink-0 ${active ? "text-primary" : "text-muted-foreground"}`}
          aria-hidden="true"
        />
        <span
          className="min-w-0 flex-1 truncate text-sm font-medium"
          title={goal.objective}
        >
          {goal.objective}
        </span>
        <Badge variant={done ? "secondary" : active ? "default" : "outline"}>
          {t.goal.status[goal.status] ?? goal.status}
        </Badge>
        {goal.status === "blocked" && goal.reason ? (
          <span className="text-muted-foreground min-w-0 truncate text-xs" title={t.goal.reason[goal.reason] ?? goal.reason}>
            {t.goal.reason[goal.reason] ?? goal.reason}
          </span>
        ) : null}
        <span className="text-muted-foreground text-xs">
          {t.goal.tokens(
            formatTokens(goal.tokensUsed),
            goal.tokenBudget ? formatTokens(goal.tokenBudget) : null,
          )}{" "}
          · {formatElapsed(goal.timeUsedSeconds)}
        </span>
        <span className="flex items-center gap-1">
          {done ? null : active ? (
            <Button
              size="sm"
              variant="ghost"
              onClick={() => set("paused")}
              disabled={actions.set.isPending}
              aria-label={t.goal.pause}
              title={t.goal.pause}
            >
              <Pause className="size-4" /> {t.goal.pause}
            </Button>
          ) : (
            <Button
              size="sm"
              variant="ghost"
              onClick={() => set("active")}
              disabled={actions.set.isPending}
              aria-label={t.goal.resume}
              title={t.goal.resume}
            >
              <Play className="size-4" /> {t.goal.resume}
            </Button>
          )}
          <Button
            size="sm"
            variant="ghost"
            onClick={onEdit}
            aria-label={t.goal.edit}
            title={t.goal.edit}
          >
            <Pencil className="size-4" />
          </Button>
          <Button
            size="sm"
            variant="ghost"
            onClick={() => actions.clear.mutate(undefined, { onError: fail })}
            disabled={actions.clear.isPending}
            aria-label={t.goal.clear}
            title={t.goal.clear}
          >
            <X className="size-4" />
          </Button>
        </span>
      </div>
    </div>
  );
}

function GoalDialog({
  open,
  onOpenChange,
  goal,
  actions,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  goal: ThreadGoal | null;
  actions: Actions;
}) {
  const [objective, setObjective] = useState("");
  const [budget, setBudget] = useState("");
  useEffect(() => {
    if (open) {
      setObjective(goal?.objective ?? "");
      setBudget(goal?.tokenBudget ? String(goal.tokenBudget) : "");
    }
  }, [open, goal]);
  const parsed = budget.trim() === "" ? null : Number(budget);
  const valid =
    objective.trim() !== "" &&
    (parsed === null || (Number.isInteger(parsed) && parsed > 0));
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent data-testid="goal-dialog">
        <DialogHeader>
          <DialogTitle>{t.goal.dialogTitle}</DialogTitle>
          <DialogDescription>{t.goal.objectiveHint}</DialogDescription>
        </DialogHeader>
        <form
          className="flex min-h-0 flex-1 flex-col gap-3"
          onSubmit={(e) => {
            e.preventDefault();
            if (!valid) return;
            actions.set.mutate(
              {
                objective: objective.trim(),
                tokenBudget: parsed,
                ...(goal && goal.status !== "active" && goal.status !== "paused"
                  ? { status: "active" as const }
                  : {}),
              },
              { onSuccess: () => onOpenChange(false), onError: fail },
            );
          }}
        >
          <DialogBody className="flex flex-col gap-3">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="goal-objective">{t.goal.objective}</Label>
              <Textarea
                id="goal-objective"
                value={objective}
                onChange={(e) => setObjective(e.target.value)}
                rows={3}
                autoFocus
              />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="goal-budget">{t.goal.budget}</Label>
              <Input
                id="goal-budget"
                inputMode="numeric"
                value={budget}
                onChange={(e) => setBudget(e.target.value)}
              />
            </div>
          </DialogBody>
          <DialogFooter>
            <Button
              type="button"
              variant="ghost"
              onClick={() => onOpenChange(false)}
            >
              {t.cancel}
            </Button>
            <Button type="submit" disabled={!valid || actions.set.isPending}>
              {t.goal.save}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
