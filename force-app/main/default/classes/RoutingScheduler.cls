/**
 * The heartbeat. Schedule this every few minutes and it keeps the floor honest:
 * expired pushes come back, SLA breaches escalate, long waits overflow, and anything
 * still queued gets another look.
 *
 * Schedule four copies 15 minutes apart for a 15 minute cadence, or call
 * RoutingScheduler.scheduleEveryQuarterHour() from anonymous Apex.
 */
public with sharing class RoutingScheduler implements Schedulable {

    public void execute(SchedulableContext context) {
        run();
    }

    public static void run() {
        WorkItemService.expirePushTimeouts();
        escalateApproachingSla();
        overflowLongWaits();
        RoutingEngine.routeAllPending();
    }

    /**
     * Bumps priority on work that has burned most of its SLA. Escalating once is
     * deliberate - repeatedly bumping everything just recreates a flat queue.
     */
    public static Integer escalateApproachingSla() {
        Datetime now = System.now();
        List<Service_Work_Item__c> candidates = [
            SELECT Id, Priority__c, Due_At__c, Requested_At__c, Queue__c, Escalated__c, Assigned_Agent__c
            FROM Service_Work_Item__c
            WHERE Escalated__c = false AND Due_At__c != NULL AND Completed_At__c = NULL
                  AND Status__c IN ('Pending', 'Routing', 'Declined', 'Assigned')
            LIMIT 200
        ];
        List<Service_Work_Item__c> toEscalate = new List<Service_Work_Item__c>();
        Decimal thresholdPercent = RoutingSettings.escalateAtPercentOfSla();

        for (Service_Work_Item__c item : candidates) {
            if (item.Requested_At__c == null) {
                continue;
            }
            Long totalMillis = item.Due_At__c.getTime() - item.Requested_At__c.getTime();
            if (totalMillis <= 0) {
                continue;
            }
            Long elapsedMillis = now.getTime() - item.Requested_At__c.getTime();
            Decimal percentUsed = (Decimal.valueOf(elapsedMillis) * 100) / Decimal.valueOf(totalMillis);
            if (percentUsed < thresholdPercent) {
                continue;
            }
            item.Escalated__c = true;
            Decimal raised = (item.Priority__c == null ? 5 : item.Priority__c) - 2;
            if (raised < 1) {
                raised = 1; // priority 1 is the ceiling
            }
            item.Priority__c = raised;
            toEscalate.add(item);
            RoutingLogger.log(item.Id, 'Escalated', item.Assigned_Agent__c, item.Queue__c,
                'Used ' + percentUsed.setScale(0) + '% of SLA - priority raised to ' + item.Priority__c);
        }
        if (!toEscalate.isEmpty()) {
            update toEscalate;
            RoutingLogger.flush();
        }
        return toEscalate.size();
    }

    /** Moves work that has waited too long into the queue's overflow queue. */
    public static Integer overflowLongWaits() {
        Map<Id, Service_Queue__c> queues = new Map<Id, Service_Queue__c>([
            SELECT Id, Name, Overflow_Queue__c, Overflow_After_Minutes__c
            FROM Service_Queue__c
            WHERE Active__c = true AND Overflow_Queue__c != NULL AND Overflow_After_Minutes__c != NULL
        ]);
        if (queues.isEmpty()) {
            return 0;
        }
        Datetime now = System.now();
        List<Service_Work_Item__c> waiting = [
            SELECT Id, Queue__c, Requested_At__c, Excluded_Agent_Ids__c
            FROM Service_Work_Item__c
            WHERE Status__c IN ('Pending', 'Declined') AND Queue__c IN :queues.keySet()
            LIMIT 200
        ];
        List<Service_Work_Item__c> toMove = new List<Service_Work_Item__c>();
        for (Service_Work_Item__c item : waiting) {
            Service_Queue__c queue = queues.get(item.Queue__c);
            if (item.Requested_At__c == null) {
                continue;
            }
            Long waitedMinutes = (now.getTime() - item.Requested_At__c.getTime()) / 60000;
            if (waitedMinutes < queue.Overflow_After_Minutes__c) {
                continue;
            }
            RoutingLogger.log(item.Id, 'Overflowed', null, queue.Id,
                'Waited ' + waitedMinutes + ' minutes in ' + queue.Name + ' - moved to overflow queue');
            item.Queue__c = queue.Overflow_Queue__c;
            item.Status__c = 'Pending';
            AgentExclusions.clear(item);
            toMove.add(item);
        }
        if (!toMove.isEmpty()) {
            update toMove;
            RoutingLogger.flush();
        }
        return toMove.size();
    }

    /** Convenience: four jobs an hour, giving a 15 minute routing heartbeat. */
    public static List<Id> scheduleEveryQuarterHour() {
        List<Id> jobIds = new List<Id>();
        for (Integer minute : new List<Integer>{0, 15, 30, 45}) {
            jobIds.add(System.schedule(
                'Service Routing Heartbeat ' + minute,
                '0 ' + minute + ' * * * ?',
                new RoutingScheduler()
            ));
        }
        return jobIds;
    }
}
