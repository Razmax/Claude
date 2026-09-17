@isTest
private class ServiceRoutingActionsTest {

    @isTest
    static void createActionRoutesACaseThroughTheRules() {
        ServiceRoutingTestFactory.stubAll();
        ServiceRoutingTestFactory.stubDefaultCaseRule('CUSTOMER_SERVICE');
        List<User> users = ServiceRoutingTestFactory.createUsers(1);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c a = ServiceRoutingTestFactory.agent(users[0], 5, null);
        ServiceRoutingTestFactory.membership(a, q, 3);

        Case c = new Case(Subject = 'Invoice is wrong', Priority = 'Medium');
        insert c;

        CreateServiceWorkItemAction.Request request = new CreateServiceWorkItemAction.Request();
        request.recordId = c.Id;
        request.channel = 'Case';

        Test.startTest();
        List<CreateServiceWorkItemAction.Result> results =
            CreateServiceWorkItemAction.execute(new List<CreateServiceWorkItemAction.Request>{request});
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assert(results[0].routed, results[0].message);
        System.assertEquals(q.Id, results[0].queueId);

        Service_Work_Item__c item = [
            SELECT Queue__c, Case__c, Source_Object__c, Subject__c, Due_At__c, Assigned_Agent__c, Status__c
            FROM Service_Work_Item__c WHERE Id = :results[0].workItemId
        ];
        System.assertEquals(c.Id, item.Case__c, 'A Case source should populate the Case lookup');
        System.assertEquals('Case', item.Source_Object__c);
        System.assertEquals('Invoice is wrong', item.Subject__c, 'Subject defaults from the source record');
        System.assertNotEquals(null, item.Due_At__c, 'The rule SLA should set a due date');
        System.assertEquals(a.Id, item.Assigned_Agent__c, 'Route Immediately defaults to true');
    }

    @isTest
    static void createActionReportsWhenNothingMatches() {
        ServiceRoutingTestFactory.stubAll();
        Case c = new Case(Subject = 'Nowhere to go');
        insert c;

        CreateServiceWorkItemAction.Request request = new CreateServiceWorkItemAction.Request();
        request.recordId = c.Id;

        Test.startTest();
        List<CreateServiceWorkItemAction.Result> results =
            CreateServiceWorkItemAction.execute(new List<CreateServiceWorkItemAction.Request>{request});
        Test.stopTest();

        System.assert(!results[0].routed);
        System.assert(results[0].message.contains('No queue matched'), results[0].message);
    }

    @isTest
    static void createActionHonoursAnExplicitQueue() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c credit = ServiceRoutingTestFactory.queue('CREDIT_REVIEW', 'Least Active');

        CreateServiceWorkItemAction.Request request = new CreateServiceWorkItemAction.Request();
        request.queueDeveloperName = 'CREDIT_REVIEW';
        request.channel = 'Credit Review';
        request.subject = 'Manual credit review';
        request.priority = 1;
        request.capacityWeight = 2;
        request.requiredSkills = 'CREDIT';
        request.slaMinutes = 60;
        request.routeImmediately = false;

        Test.startTest();
        List<CreateServiceWorkItemAction.Result> results =
            CreateServiceWorkItemAction.execute(new List<CreateServiceWorkItemAction.Request>{request});
        Test.stopTest();

        Service_Work_Item__c item = [
            SELECT Queue__c, Priority__c, Capacity_Weight__c, Required_Skills__c, Status__c, Assigned_Agent__c
            FROM Service_Work_Item__c WHERE Id = :results[0].workItemId
        ];
        System.assertEquals(credit.Id, item.Queue__c);
        System.assertEquals(1, item.Priority__c.intValue());
        System.assertEquals(2, item.Capacity_Weight__c.intValue());
        System.assertEquals('CREDIT', item.Required_Skills__c);
        System.assertEquals(null, item.Assigned_Agent__c, 'Route Immediately was false');
    }

    @isTest
    static void routeActionSweepsTheBacklog() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(1);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c a = ServiceRoutingTestFactory.agent(users[0], 5, null);
        ServiceRoutingTestFactory.membership(a, q, 3);
        ServiceRoutingTestFactory.workItems(q, 3, 5, 1);

        RouteServiceWorkItemAction.Request request = new RouteServiceWorkItemAction.Request();
        request.queueId = q.Id;

        Test.startTest();
        List<RouteServiceWorkItemAction.Result> results =
            RouteServiceWorkItemAction.execute(new List<RouteServiceWorkItemAction.Request>{request});
        Test.stopTest();

        System.assertEquals(3, results[0].assignedCount);
        System.assertEquals(0, results[0].unassignedCount);
    }

    @isTest
    static void transferActionResolvesQueueByName() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c source = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Queue__c target = ServiceRoutingTestFactory.queue('CREDIT_REVIEW', 'Least Active');
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(source);

        TransferServiceWorkItemAction.Request request = new TransferServiceWorkItemAction.Request();
        request.workItemId = item.Id;
        request.targetQueueDeveloperName = 'CREDIT_REVIEW';
        request.reason = 'Needs a credit decision';

        Test.startTest();
        List<TransferServiceWorkItemAction.Result> results =
            TransferServiceWorkItemAction.execute(new List<TransferServiceWorkItemAction.Request>{request});
        Test.stopTest();

        System.assert(results[0].success, results[0].message);
        System.assertEquals(target.Id, [SELECT Queue__c FROM Service_Work_Item__c WHERE Id = :item.Id].Queue__c);
    }

    @isTest
    static void transferActionExplainsBadInput() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c source = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(source);

        TransferServiceWorkItemAction.Request unknownQueue = new TransferServiceWorkItemAction.Request();
        unknownQueue.workItemId = item.Id;
        unknownQueue.targetQueueDeveloperName = 'NOT_A_QUEUE';

        TransferServiceWorkItemAction.Request noTarget = new TransferServiceWorkItemAction.Request();
        noTarget.workItemId = item.Id;

        Test.startTest();
        List<TransferServiceWorkItemAction.Result> results = TransferServiceWorkItemAction.execute(
            new List<TransferServiceWorkItemAction.Request>{unknownQueue, noTarget});
        Test.stopTest();

        System.assert(!results[0].success);
        System.assert(results[0].message.contains('NOT_A_QUEUE'), results[0].message);
        System.assert(!results[1].success);
        System.assert(results[1].message.contains('target queue or a target agent'), results[1].message);
    }

    @isTest
    static void completeActionFindsWorkFromTheSourceRecord() {
        ServiceRoutingTestFactory.stubAll();
        ServiceRoutingTestFactory.stubDefaultCaseRule('CUSTOMER_SERVICE');
        List<User> users = ServiceRoutingTestFactory.createUsers(1);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c a = ServiceRoutingTestFactory.agent(users[0], 5, null);
        ServiceRoutingTestFactory.membership(a, q, 3);

        Case c = new Case(Subject = 'Close me');
        insert c;
        CreateServiceWorkItemAction.Request create = new CreateServiceWorkItemAction.Request();
        create.recordId = c.Id;
        create.channel = 'Case';
        CreateServiceWorkItemAction.execute(new List<CreateServiceWorkItemAction.Request>{create});

        CompleteServiceWorkItemAction.Request complete = new CompleteServiceWorkItemAction.Request();
        complete.sourceRecordId = c.Id;
        complete.closeReason = 'Resolved';

        Test.startTest();
        List<CompleteServiceWorkItemAction.Result> results =
            CompleteServiceWorkItemAction.execute(new List<CompleteServiceWorkItemAction.Request>{complete});
        Test.stopTest();

        System.assert(results[0].success, results[0].message);
        System.assertEquals('Completed',
            [SELECT Status__c FROM Service_Work_Item__c WHERE Source_Record_Id__c = :String.valueOf(c.Id)].Status__c);
    }

    @isTest
    static void completeActionReportsMissingWork() {
        ServiceRoutingTestFactory.stubAll();
        Case c = new Case(Subject = 'No work item');
        insert c;

        CompleteServiceWorkItemAction.Request request = new CompleteServiceWorkItemAction.Request();
        request.sourceRecordId = c.Id;

        Test.startTest();
        List<CompleteServiceWorkItemAction.Result> results =
            CompleteServiceWorkItemAction.execute(new List<CompleteServiceWorkItemAction.Request>{request});
        Test.stopTest();

        System.assert(!results[0].success);
        System.assert(results[0].message.contains('No open work item'), results[0].message);
    }

    @isTest
    static void cancelPathOfTheCompleteAction() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);

        CompleteServiceWorkItemAction.Request request = new CompleteServiceWorkItemAction.Request();
        request.workItemId = item.Id;
        request.cancelInstead = true;
        request.closeReason = 'Customer withdrew';

        Test.startTest();
        CompleteServiceWorkItemAction.execute(new List<CompleteServiceWorkItemAction.Request>{request});
        Test.stopTest();

        System.assertEquals('Canceled', [SELECT Status__c FROM Service_Work_Item__c WHERE Id = :item.Id].Status__c);
    }

    @isTest
    static void presenceActionSetsStatusAndRejectsUnknownOnes() {
        ServiceRoutingTestFactory.stubAll();

        SetAgentPresenceAction.Request good = new SetAgentPresenceAction.Request();
        good.presenceStatus = ServiceRoutingTestFactory.AVAILABLE;

        SetAgentPresenceAction.Request bad = new SetAgentPresenceAction.Request();
        bad.presenceStatus = 'Not_A_Real_Status';

        Test.startTest();
        List<SetAgentPresenceAction.Result> results =
            SetAgentPresenceAction.execute(new List<SetAgentPresenceAction.Request>{good, bad});
        Test.stopTest();

        System.assert(results[0].success, results[0].message);
        System.assertNotEquals(null, results[0].agentId);
        System.assert(!results[1].success);
        System.assert(results[1].message.contains('Unknown presence status'), results[1].message);
    }
}
