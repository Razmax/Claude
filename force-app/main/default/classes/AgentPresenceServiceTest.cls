@isTest
private class AgentPresenceServiceTest {

    @isTest
    static void firstLoginCreatesAnAgentRecord() {
        ServiceRoutingTestFactory.stubAll();

        Test.startTest();
        Service_Agent__c agent = AgentPresenceService.ensureAgent(UserInfo.getUserId());
        Service_Agent__c again = AgentPresenceService.ensureAgent(UserInfo.getUserId());
        Test.stopTest();

        System.assertEquals(agent.Id, again.Id, 'A second call must reuse the same agent record');
        System.assertEquals(1, [SELECT COUNT() FROM Service_Agent__c WHERE User__c = :UserInfo.getUserId()]);
        System.assert(!agent.Accepts_Work__c, 'A brand new agent starts unavailable');
    }

    @isTest
    static void goingOfflineRecallsUnacceptedWork() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(1);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c agent = ServiceRoutingTestFactory.agent(users[0], 5, null);
        ServiceRoutingTestFactory.membership(agent, q, 3);

        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});
        System.assertEquals(agent.Id,
            [SELECT Assigned_Agent__c FROM Service_Work_Item__c WHERE Id = :item.Id].Assigned_Agent__c);

        Test.startTest();
        AgentPresenceService.setPresence(users[0].Id, ServiceRoutingTestFactory.OFFLINE, null);
        Test.stopTest();

        Service_Work_Item__c after = [
            SELECT Status__c, Assigned_Agent__c FROM Service_Work_Item__c WHERE Id = :item.Id
        ];
        System.assertEquals(null, after.Assigned_Agent__c,
            'Work nobody accepted should not sit on a dark screen');
        System.assertEquals('Pending', after.Status__c);

        Service_Agent__c reloaded = [
            SELECT Accepts_Work__c, Current_Load__c, Presence_Status_Label__c
            FROM Service_Agent__c WHERE Id = :agent.Id
        ];
        System.assert(!reloaded.Accepts_Work__c);
        System.assertEquals(0, reloaded.Current_Load__c.intValue());
        System.assertEquals('Offline', reloaded.Presence_Status_Label__c);
    }

    @isTest
    static void acceptedWorkStaysWithTheAgentWhenTheyStepAway() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(1);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c agent = ServiceRoutingTestFactory.agent(users[0], 5, null);
        ServiceRoutingTestFactory.membership(agent, q, 3);

        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});
        WorkItemService.accept(item.Id, users[0].Id);

        Test.startTest();
        AgentPresenceService.setPresence(users[0].Id, ServiceRoutingTestFactory.OFFLINE, null);
        Test.stopTest();

        Service_Work_Item__c after = [
            SELECT Status__c, Assigned_Agent__c FROM Service_Work_Item__c WHERE Id = :item.Id
        ];
        System.assertEquals(agent.Id, after.Assigned_Agent__c,
            'Accepted work is a conversation in flight - it stays with the agent');
        System.assertEquals('Accepted', after.Status__c);
    }

    @isTest
    static void statusesRequiringAReasonEnforceIt() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(1);

        Test.startTest();
        try {
            AgentPresenceService.setPresence(users[0].Id, 'Coaching', null);
            System.assert(false, 'Coaching requires a reason');
        } catch (RoutingException e) {
            System.assert(e.getMessage().contains('reason is required'), e.getMessage());
        }
        Service_Agent__c agent = AgentPresenceService.setPresence(users[0].Id, 'Coaching', 'Weekly one to one');
        Test.stopTest();

        System.assertEquals('Coaching', agent.Presence_Status_Label__c);
        System.assert(!agent.Accepts_Work__c);
    }

    @isTest
    static void capacityOverrideCapsAnAgentWhileTraining() {
        ServiceRoutingTestFactory.stubSettings();
        PresenceStatusService.overrideStatuses(new Map<String, Service_Presence_Status__mdt>{
            'Training' => new Service_Presence_Status__mdt(
                DeveloperName = 'Training', MasterLabel = 'Training', Active__c = true,
                Status_Category__c = 'Available', Accepts_Work__c = true, Capacity_Override__c = 2)
        });

        Service_Agent__c agent = new Service_Agent__c(Max_Capacity__c = 10, Presence_Status__c = 'Training');
        System.assertEquals(2, PresenceStatusService.effectiveCapacity(agent).intValue(),
            'A status override should cap capacity below the configured maximum');

        agent.Presence_Status__c = null;
        System.assertEquals(10, PresenceStatusService.effectiveCapacity(agent).intValue(),
            'With no status override the configured maximum applies');
    }
}
