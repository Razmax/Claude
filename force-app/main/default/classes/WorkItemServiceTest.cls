@isTest
private class WorkItemServiceTest {

    private static Service_Queue__c q;
    private static Service_Agent__c agentOne;
    private static Service_Agent__c agentTwo;
    private static List<User> users;

    private static void setup(Integer agentCount) {
        ServiceRoutingTestFactory.stubAll();
        users = ServiceRoutingTestFactory.createUsers(agentCount);
        q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        agentOne = ServiceRoutingTestFactory.agent(users[0], 5, 'BILLING');
        ServiceRoutingTestFactory.membership(agentOne, q, 3);
        if (agentCount > 1) {
            agentTwo = ServiceRoutingTestFactory.agent(users[1], 5, 'BILLING');
            ServiceRoutingTestFactory.membership(agentTwo, q, 3);
        }
    }

    @isTest
    static void acceptMovesWorkForwardAndClearsTheTimeout() {
        setup(1);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});

        Test.startTest();
        WorkItemService.accept(item.Id, users[0].Id);
        Test.stopTest();

        Service_Work_Item__c after = [
            SELECT Status__c, Accepted_At__c, Push_Expires_At__c FROM Service_Work_Item__c WHERE Id = :item.Id
        ];
        System.assertEquals('Accepted', after.Status__c);
        System.assertNotEquals(null, after.Accepted_At__c);
        System.assertEquals(null, after.Push_Expires_At__c, 'Accepting cancels the push timeout');
    }

    @isTest
    static void acceptingSomeoneElsesWorkIsRejected() {
        setup(2);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});
        Service_Work_Item__c routed = [SELECT Assigned_User__c FROM Service_Work_Item__c WHERE Id = :item.Id];
        Id otherUser = routed.Assigned_User__c == users[0].Id ? users[1].Id : users[0].Id;

        Test.startTest();
        try {
            WorkItemService.accept(item.Id, otherUser);
            System.assert(false, 'Accepting another agent work should throw');
        } catch (Exception e) {
            System.assert(e.getMessage().contains('assigned to someone else'), e.getMessage());
        }
        Test.stopTest();
    }

    @isTest
    static void decliningReturnsWorkAndExcludesTheAgent() {
        setup(2);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});
        Service_Work_Item__c routed = [
            SELECT Assigned_Agent__c, Assigned_User__c FROM Service_Work_Item__c WHERE Id = :item.Id
        ];
        Id firstAgent = routed.Assigned_Agent__c;

        Test.startTest();
        WorkItemService.decline(item.Id, routed.Assigned_User__c, 'Wrong skill set');
        Test.stopTest();

        Service_Work_Item__c after = [
            SELECT Status__c, Assigned_Agent__c, Decline_Count__c, Excluded_Agent_Ids__c
            FROM Service_Work_Item__c WHERE Id = :item.Id
        ];
        System.assertEquals(1, after.Decline_Count__c.intValue());
        System.assert(after.Excluded_Agent_Ids__c.contains(String.valueOf(firstAgent)),
            'The declining agent should be recorded so they are not offered it again');
        // The queueable re-route runs at stopTest, so the item should now sit with the other agent.
        System.assertNotEquals(firstAgent, after.Assigned_Agent__c,
            'After a decline the item must not return to the same agent');

        Service_Agent__c releasedAgent = [
            SELECT Current_Load__c, Active_Work_Count__c FROM Service_Agent__c WHERE Id = :firstAgent
        ];
        System.assertEquals(0, releasedAgent.Current_Load__c.intValue(), 'Declining frees the capacity again');
    }

    @isTest
    static void repeatedDeclinesParkTheItemForASupervisor() {
        ServiceRoutingTestFactory.stubPresenceStatuses();
        ServiceRoutingTestFactory.stubSettings(1, 30); // one decline is the limit
        ServiceRoutingTestFactory.stubRules(new List<Service_Routing_Rule__mdt>());
        users = ServiceRoutingTestFactory.createUsers(1);
        q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        agentOne = ServiceRoutingTestFactory.agent(users[0], 5, null);
        ServiceRoutingTestFactory.membership(agentOne, q, 3);

        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});

        Test.startTest();
        WorkItemService.decline(item.Id, users[0].Id, 'Not mine');
        Test.stopTest();

        Service_Work_Item__c after = [
            SELECT Status__c, Assigned_Agent__c, Last_Routing_Error__c
            FROM Service_Work_Item__c WHERE Id = :item.Id
        ];
        System.assertEquals('Pending', after.Status__c);
        System.assertEquals(null, after.Assigned_Agent__c);
        System.assert(after.Last_Routing_Error__c.contains('supervisor'),
            'The item should flag that it needs a human decision: ' + after.Last_Routing_Error__c);
    }

    @isTest
    static void completingFreesCapacity() {
        setup(1);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});
        WorkItemService.accept(item.Id, users[0].Id);

        Test.startTest();
        WorkItemService.complete(item.Id, users[0].Id, 'Resolved');
        Test.stopTest();

        Service_Work_Item__c after = [
            SELECT Status__c, Completed_At__c, Close_Reason__c FROM Service_Work_Item__c WHERE Id = :item.Id
        ];
        System.assertEquals('Completed', after.Status__c);
        System.assertEquals('Resolved', after.Close_Reason__c);
        System.assertNotEquals(null, after.Completed_At__c);

        Service_Agent__c after2 = [SELECT Current_Load__c, Active_Work_Count__c FROM Service_Agent__c WHERE Id = :agentOne.Id];
        System.assertEquals(0, after2.Current_Load__c.intValue());
        System.assertEquals(0, after2.Active_Work_Count__c.intValue());
    }

    @isTest
    static void transferToAnotherQueueResetsTheItem() {
        setup(1);
        Service_Queue__c credit = ServiceRoutingTestFactory.queue('CREDIT_REVIEW', 'Least Active');
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});

        Test.startTest();
        WorkItemService.transfer(item.Id, credit.Id, null, 'Customer needs a credit decision');
        Test.stopTest();

        Service_Work_Item__c after = [
            SELECT Queue__c, Status__c, Assigned_Agent__c, Transfer_Reason__c, Excluded_Agent_Ids__c
            FROM Service_Work_Item__c WHERE Id = :item.Id
        ];
        System.assertEquals(credit.Id, after.Queue__c);
        System.assertEquals(null, after.Assigned_Agent__c);
        System.assertEquals('Customer needs a credit decision', after.Transfer_Reason__c);
        System.assertEquals(null, after.Excluded_Agent_Ids__c, 'A queue transfer starts the exclusion list fresh');
    }

    @isTest
    static void transferDirectToAnAgentAssignsImmediately() {
        setup(2);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);

        Test.startTest();
        WorkItemService.transfer(item.Id, null, agentTwo.Id, 'Team lead is taking this');
        Test.stopTest();

        Service_Work_Item__c after = [
            SELECT Assigned_Agent__c, Assigned_User__c, Status__c FROM Service_Work_Item__c WHERE Id = :item.Id
        ];
        System.assertEquals(agentTwo.Id, after.Assigned_Agent__c);
        System.assertEquals(users[1].Id, after.Assigned_User__c);
        System.assertEquals('Assigned', after.Status__c);
    }

    @isTest
    static void pushTimeoutsComeBackToTheQueue() {
        setup(2);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});

        // Pretend the agent never answered.
        Service_Work_Item__c routed = [
            SELECT Id, Assigned_Agent__c, Push_Expires_At__c FROM Service_Work_Item__c WHERE Id = :item.Id
        ];
        Id timedOutAgent = routed.Assigned_Agent__c;
        routed.Push_Expires_At__c = System.now().addMinutes(-1);
        RoutingEngine.suppressTriggerRouting = true;
        update routed;
        RoutingEngine.suppressTriggerRouting = false;

        Test.startTest();
        Integer expired = WorkItemService.expirePushTimeouts();
        Test.stopTest();

        System.assertEquals(1, expired);
        Service_Work_Item__c after = [
            SELECT Assigned_Agent__c, Decline_Count__c, Excluded_Agent_Ids__c
            FROM Service_Work_Item__c WHERE Id = :item.Id
        ];
        System.assertEquals(1, after.Decline_Count__c.intValue(), 'A timeout counts as a decline');
        System.assert(after.Excluded_Agent_Ids__c.contains(String.valueOf(timedOutAgent)));
        System.assertNotEquals(timedOutAgent, after.Assigned_Agent__c,
            'The item should move on rather than sit on an unattended screen');
    }

    @isTest
    static void capacityRecalculationSelfHeals() {
        setup(1);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});

        // Simulate drift, as if someone edited records directly.
        Service_Agent__c drifted = [SELECT Id, Current_Load__c FROM Service_Agent__c WHERE Id = :agentOne.Id];
        drifted.Current_Load__c = 99;
        drifted.Active_Work_Count__c = 99;
        update drifted;

        Test.startTest();
        WorkItemService.recalculateAgentLoad(new Set<Id>{agentOne.Id});
        Test.stopTest();

        Service_Agent__c fixed = [SELECT Current_Load__c, Active_Work_Count__c FROM Service_Agent__c WHERE Id = :agentOne.Id];
        System.assertEquals(1, fixed.Current_Load__c.intValue(), 'Load is derived from real open work, not a counter');
        System.assertEquals(1, fixed.Active_Work_Count__c.intValue());
    }

    @isTest
    static void cancelReleasesTheAgent() {
        setup(1);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});

        Test.startTest();
        WorkItemService.cancel(item.Id, 'Customer withdrew the request');
        Test.stopTest();

        Service_Work_Item__c after = [SELECT Status__c FROM Service_Work_Item__c WHERE Id = :item.Id];
        System.assertEquals('Canceled', after.Status__c);
        Service_Agent__c agent = [SELECT Current_Load__c FROM Service_Agent__c WHERE Id = :agentOne.Id];
        System.assertEquals(0, agent.Current_Load__c.intValue());
    }

    @isTest
    static void startWorkMarksItemInProgress() {
        setup(1);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});
        WorkItemService.accept(item.Id, users[0].Id);

        Test.startTest();
        WorkItemService.startWork(item.Id, users[0].Id);
        Test.stopTest();

        Service_Work_Item__c after = [SELECT Status__c FROM Service_Work_Item__c WHERE Id = :item.Id];
        System.assertEquals('In Progress', after.Status__c);
    }

    @isTest
    static void exclusionsLapseAfterTheCooldown() {
        ServiceRoutingTestFactory.stubSettings();
        Service_Work_Item__c item = new Service_Work_Item__c();
        Id fakeAgent = ServiceRoutingTestFactory.createUsers(1)[0].Id;

        AgentExclusions.exclude(item, fakeAgent);
        System.assertEquals(1, AgentExclusions.activeExclusions(item).size(), 'A fresh decline is active');

        // An entry stamped before the cooldown window should be ignored.
        item.Excluded_Agent_Ids__c = fakeAgent + '|' + (System.now().addMinutes(-60).getTime());
        System.assertEquals(0, AgentExclusions.activeExclusions(item).size(),
            'Exclusions must expire so short-staffed queues retry everyone');

        AgentExclusions.clear(item);
        System.assertEquals(null, item.Excluded_Agent_Ids__c);
    }
}
