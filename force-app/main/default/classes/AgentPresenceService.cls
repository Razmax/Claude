/**
 * Everything that happens when an agent changes their availability.
 *
 * Going unavailable is the interesting case: work they accepted stays with them (they
 * are mid-conversation), but work merely pushed and not yet accepted goes back to the
 * queue so it is not sitting on a dark screen.
 */
public with sharing class AgentPresenceService {

    /** Returns the agent record for a user, creating one on first login if needed. */
    public static Service_Agent__c ensureAgent(Id userId) {
        List<Service_Agent__c> existing = [
            SELECT Id, Name, User__c, Is_Active__c, Presence_Status__c, Presence_Status_Label__c,
                   Presence_Since__c, Accepts_Work__c, Max_Capacity__c, Current_Load__c,
                   Active_Work_Count__c, Last_Assigned_At__c, Skills__c
            FROM Service_Agent__c WHERE User__c = :userId LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0];
        }
        User u = [SELECT Id, Name FROM User WHERE Id = :userId LIMIT 1];
        Service_Agent__c agent = new Service_Agent__c(
            Name = u.Name,
            User__c = userId,
            User_Id_Key__c = String.valueOf(userId).substring(0, 15),
            Is_Active__c = true,
            Accepts_Work__c = false,
            Max_Capacity__c = 5,
            Current_Load__c = 0,
            Active_Work_Count__c = 0
        );
        insert agent;
        return agent;
    }

    /**
     * Applies a presence status and deals with the consequences: recall unaccepted work
     * when going offline, look for waiting work when coming back.
     */
    public static Service_Agent__c setPresence(Id userId, String statusDeveloperName, String reason) {
        Service_Agent__c agent = ensureAgent(userId);
        Service_Presence_Status__mdt status = PresenceStatusService.find(statusDeveloperName);
        if (status == null) {
            throw new RoutingException('Unknown presence status: ' + statusDeveloperName);
        }
        if (status.Requires_Reason__c == true && String.isBlank(reason)) {
            throw new RoutingException('A reason is required for the status ' + status.MasterLabel + '.');
        }
        Boolean wasAcceptingWork = agent.Accepts_Work__c == true;
        String previousStatus = agent.Presence_Status_Label__c;

        PresenceStatusService.applyStatus(agent, status);
        update agent;

        RoutingLogger.log(null, 'Presence Change', agent.Id, null,
            'Presence ' + previousStatus + ' -> ' + status.MasterLabel
                + (String.isBlank(reason) ? '' : ' (' + reason + ')'));
        RoutingLogger.flush();

        Boolean nowAcceptingWork = status.Accepts_Work__c == true;
        if (wasAcceptingWork && !nowAcceptingWork && RoutingSettings.get().Requeue_On_Offline__c == true) {
            WorkItemService.requeueUnaccepted(new Set<Id>{agent.Id},
                'Agent moved to ' + status.MasterLabel);
        } else if (!wasAcceptingWork && nowAcceptingWork) {
            WorkItemService.routeAsync(null);
        }
        return agent;
    }
}
