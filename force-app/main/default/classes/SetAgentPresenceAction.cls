/**
 * Flow action: change an agent's presence status.
 *
 * Lets you build the surrounding process declaratively - set everyone to Offline at end
 * of shift, flip a team to Credit Review during a backlog push, or prompt a rep to go
 * Available after training completes.
 */
public with sharing class SetAgentPresenceAction {

    public class Request {
        @InvocableVariable(label='User Id' description='Defaults to the running user.')
        public Id userId;

        @InvocableVariable(label='Presence Status' description='DeveloperName of a Service Presence Status record.' required=true)
        public String presenceStatus;

        @InvocableVariable(label='Reason')
        public String reason;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Agent Id')
        public Id agentId;

        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(
        label='Set Agent Presence'
        description='Sets an agent presence status, recalling unaccepted work when they stop accepting.'
        category='Service Routing')
    public static List<Result> execute(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests) {
            Result result = new Result();
            try {
                Id userId = request.userId == null ? UserInfo.getUserId() : request.userId;
                Service_Agent__c agent = AgentPresenceService.setPresence(userId, request.presenceStatus, request.reason);
                result.success = true;
                result.agentId = agent.Id;
                result.message = 'Presence set to ' + agent.Presence_Status_Label__c + '.';
            } catch (Exception e) {
                result.success = false;
                result.message = e.getMessage();
            }
            results.add(result);
        }
        return results;
    }
}
