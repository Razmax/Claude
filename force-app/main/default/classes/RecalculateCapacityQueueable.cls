/** Recomputes agent capacity after the transaction that changed their work commits. */
public with sharing class RecalculateCapacityQueueable implements Queueable {
    private Set<Id> agentIds;

    public RecalculateCapacityQueueable(Set<Id> agentIds) {
        this.agentIds = agentIds;
    }

    public void execute(QueueableContext context) {
        WorkItemService.recalculateAgentLoad(agentIds);
    }

    /** Safe to call from a trigger: runs inline when already async, skips when out of jobs. */
    public static void enqueue(Set<Id> agentIds) {
        if (agentIds == null || agentIds.isEmpty()) {
            return;
        }
        if (System.isBatch() || System.isFuture() || System.isQueueable()) {
            WorkItemService.recalculateAgentLoad(agentIds);
            return;
        }
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return;
        }
        System.enqueueJob(new RecalculateCapacityQueueable(agentIds));
    }
}
