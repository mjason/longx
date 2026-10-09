import { useTranslation } from "react-i18next";

// Detailed job guidance loads with the job UI, not every conversation entry.
const zh = {
  title: (running: number, pending: number, processing: number) => `等待结果 · ${running} 项运行中，${pending} 项待处理${processing ? `，${processing} 项处理中` : ""}`,
  checkMessage: "继续检查待处理的任务结果，确认后再汇总；不要重跑我已停止的任务。",
  purposeHint: "改为独立后台后，此任务不再阻止本次工作完成。只用于不依赖结果的服务或监控；验证、构建等应保持“需要等结果”。",
  waitHint: "改为需要等结果后，此任务会阻止本次工作完成，直到结果被检查并确认。",
  backgroundHint: "独立运行，不计入等待结果。停止本轮不会停止这些任务。",
  hint: "本次工作尚未完成，结果回来后会自动接续。建议等最终汇总后再验收；可以补充要求或切换会话。",
  manualHint: "本次工作尚未完成。有任务未启用结束唤醒，结果需主动检查。建议等最终汇总后再验收。",
  pendingHint: "结果已到但尚未确认，本次工作仍未完成。请继续会话让 agent 检查结果，再按最终汇总验收。",
  pausedHint: "自动接续已暂停。后台任务仍可能运行；结果回来后需由你继续会话。",
  incompleteHint: "有失败或被停止的任务，本次验证未完成。处理并确认结果前，请勿按已完成验收。",
  inputHint: "留意任务栏：仍有工作未完成，任务结果、定时或监控消息可能与新消息交错到达，影响内容顺序。可以照常输入和发送。",
  stopHint: "将停止任务及其子进程，不会停止其他任务或 agent。需要等待的任务将保留“未完成”状态，不会自动重跑。",
};
const en: typeof zh = {
  title: (running: number, pending: number, processing: number) => `Awaiting results · ${running} running, ${pending} pending${processing ? `, ${processing} processing` : ""}`,
  checkMessage: "Continue reviewing pending job results and summarize once confirmed. Do not restart jobs I stopped.",
  purposeHint: "An independent background job no longer prevents this work from finishing. Use this only for independent services or monitors; tests and builds should remain result-required.",
  waitHint: "Requiring a result makes this job prevent completion until its result is checked and confirmed.",
  backgroundHint: "Runs independently and does not count as pending work. Stopping a turn does not stop these jobs.",
  hint: "This work is not finished. The agent will resume when results arrive. Wait for the final summary before acceptance; you can add instructions or switch conversations.",
  manualHint: "This work is not finished. Some jobs do not wake the agent on exit and need an explicit result check. Wait for the final summary before acceptance.",
  pendingHint: "Results have arrived but are not confirmed. This work is still unfinished. Continue the conversation to have the agent review them before acceptance.",
  pausedHint: "Automatic resumption is paused. Background jobs may still be running; resume the conversation to process their results.",
  incompleteHint: "Some jobs failed or were stopped. Verification is incomplete; do not accept this work as finished until results are handled and confirmed.",
  inputHint: "Check the task bar: work is still unfinished. Job results, scheduled or monitoring messages may interleave with your new messages. You can still type and send normally.",
  stopHint: "Stops this job and its child processes, not other jobs or agents. Result-required work remains incomplete and will not automatically restart.",
};

export function useJobHints() {
  const { i18n } = useTranslation();
  return (i18n.resolvedLanguage ?? i18n.language).startsWith("en") ? en : zh;
}
