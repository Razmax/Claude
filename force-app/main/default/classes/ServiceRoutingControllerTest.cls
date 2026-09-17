@isTest
private class ServiceRoutingControllerTest {

    /**
     * The console always acts as the running user, so these tests set the running user up
     * as the agent rather than creating a separate one.
     */
    private static Service_Agent__c meAsAgent(Service_Queue__c q, Decimal capacity, String skills) {
        Service_Agent__c me = new Service_Agent__c(
            Name = UserInfo.getName(),
            User__c = UserInfo.getUserId(),
            User_Id_Key__c = String.valueOf(UserInfo.getUserId()).substring(0, 15),
            Is_Active__c = true,
            Presence_Status__c = ServiceRoutingTestFactory.AVAILABLE,
            Presence_Status_Label__c = 'Available',
            Accepts_Work__c = true,
            Max_Capacity__c = capacity,
            Current_Load__c = 0,
            Active_Work_Count__c = 0,
            Skills__c = skills
        );
        insert me;
        ServiceRoutingTestFactory.membership(me, q, 3);
        return me;
    }

    @isTest
    static void consoleShowsPresenceCapacityAndWork() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c me = meAsAgent(q, 5, null);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});

        Test.startTest();
        ServiceRoutingConsoleController.ConsoleState state = ServiceRoutingConsoleController.getConsoleState();
        Test.stopTest();

        System.assertEquals(me.Id, state.agentId);
        System.assertEquals('Available', state.presenceLabel);
        System.assert(state.acceptsWork);
        System.assertEquals(1, state.myWork.size(), 'The pushed item should be in my work list');
        System.assertEquals('Assigned', state.myWork[0].status);
        System.assert(state.myWork[0].canAccept, 'A pushed item can be accepted');
        System.assert(state.myWork[0].canDecline);
        System.assertEquals(4, state.remainingCapacity.intValue(), 'Capacity 5 minus one weight-1 item');
        System.assert(!state.presenceOptions.isEmpty(), 'Presence options come from custom metadata');
    }

    @isTest
    static void acceptAndCompleteThroughTheConsole() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        meAsAgent(q, 5, null);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});

        Test.startTest();
        ServiceRoutingConsoleController.ConsoleState afterAccept =
            ServiceRoutingConsoleController.acceptWork(item.Id);
        System.assertEquals('Accepted', afterAccept.myWork[0].status);

        ServiceRoutingConsoleController.startWork(item.Id);
        ServiceRoutingConsoleController.ConsoleState afterComplete =
            ServiceRoutingConsoleController.completeWork(item.Id, 'Resolved');
        Test.stopTest();

        System.assertEquals(0, afterComplete.myWork.size(), 'Completed work leaves the list');
        System.assertEquals(0, afterComplete.currentLoad.intValue(), 'Capacity is released');
    }

    @isTest
    static void declineThroughTheConsoleReturnsWorkToTheQueue() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        meAsAgent(q, 5, null);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});

        Test.startTest();
        ServiceRoutingConsoleController.declineWork(item.Id, 'Not my area');
        Test.stopTest();

        Service_Work_Item__c after = [SELECT Decline_Count__c FROM Service_Work_Item__c WHERE Id = :item.Id];
        System.assertEquals(1, after.Decline_Count__c.intValue());
    }

    @isTest
    static void agentsCanPullWaitingWork() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        meAsAgent(q, 5, null);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);

        Test.startTest();
        ServiceRoutingConsoleController.ConsoleState state = ServiceRoutingConsoleController.pullWork(item.Id);
        Test.stopTest();

        System.assertEquals(1, state.myWork.size());
        System.assertEquals('Accepted', state.myWork[0].status, 'Pulled work is accepted immediately');
        System.assertEquals(0, state.availableWork.size(), 'It is no longer waiting in the queue');
    }

    @isTest
    static void pullingSkilledWorkWithoutTheSkillIsBlocked() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CREDIT_REVIEW', 'Skill Based');
        meAsAgent(q, 5, 'BILLING');
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        item.Required_Skills__c = 'CREDIT';
        update item;

        Test.startTest();
        try {
            ServiceRoutingConsoleController.pullWork(item.Id);
            System.assert(false, 'Pulling work you are not skilled for should throw');
        } catch (Exception e) {
            System.assert(e instanceof AuraHandledException, 'Errors reach the UI as AuraHandledException');
        }
        Test.stopTest();
    }

    @isTest
    static void pullingWhenFullIsBlocked() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c me = meAsAgent(q, 1, null);
        List<Service_Work_Item__c> items = ServiceRoutingTestFactory.workItems(q, 2, 5, 1);
        ServiceRoutingConsoleController.pullWork(items[0].Id);

        Test.startTest();
        try {
            ServiceRoutingConsoleController.pullWork(items[1].Id);
            System.assert(false, 'A full agent should not be able to pull more work');
        } catch (Exception e) {
            System.assert(e instanceof AuraHandledException);
        }
        Test.stopTest();
    }

    @isTest
    static void presenceChangeFromTheConsole() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        meAsAgent(q, 5, null);

        Test.startTest();
        ServiceRoutingConsoleController.ConsoleState state =
            ServiceRoutingConsoleController.setPresence(ServiceRoutingTestFactory.OFFLINE, null);
        Test.stopTest();

        System.assertEquals('Offline', state.presenceLabel);
        System.assert(!state.acceptsWork);
    }

    @isTest
    static void transferQueueOptionsAreListed() {
        ServiceRoutingTestFactory.stubAll();
        ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        ServiceRoutingTestFactory.queue('CREDIT_REVIEW', 'Least Active');

        Test.startTest();
        List<Map<String, String>> options = ServiceRoutingConsoleController.getTransferQueues();
        Test.stopTest();

        System.assertEquals(2, options.size());
    }

    @isTest
    static void consoleTransferMovesTheItem() {
        ServiceRoutingTestFactory.stubAll();
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Queue__c credit = ServiceRoutingTestFactory.queue('CREDIT_REVIEW', 'Least Active');
        meAsAgent(q, 5, null);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);
        RoutingEngine.route(new Set<Id>{item.Id});

        Test.startTest();
        ServiceRoutingConsoleController.transferWork(item.Id, credit.Id, null, 'Credit needs to look');
        Test.stopTest();

        System.assertEquals(credit.Id, [SELECT Queue__c FROM Service_Work_Item__c WHERE Id = :item.Id].Queue__c);
    }

    // ------------------------------------------------------------------ supervisor

    @isTest
    static void supervisorDashboardSummarisesQueuesAndAgents() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(1);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        q.Max_Queue_Depth_Alert__c = 1;
        update q;
        Service_Agent__c a = ServiceRoutingTestFactory.agent(users[0], 1, null);
        ServiceRoutingTestFactory.membership(a, q, 3);

        List<Service_Work_Item__c> items = ServiceRoutingTestFactory.workItems(q, 3, 5, 1);
        RoutingEngine.route(new Set<Id>{items[0].Id});

        Test.startTest();
        ServiceSupervisorController.Dashboard dashboard = ServiceSupervisorController.getDashboard();
        Test.stopTest();

        System.assertEquals(1, dashboard.queues.size());
        ServiceSupervisorController.QueueStat stat = dashboard.queues[0];
        System.assertEquals(2, stat.waiting, 'Two items are still queued');
        System.assertEquals(1, stat.assigned, 'One item was pushed to an agent');
        System.assertEquals(1, stat.availableAgents);
        System.assert(stat.overThreshold, 'Waiting count exceeds the alert threshold of 1');
        System.assert(!dashboard.agents.isEmpty());
        System.assert(dashboard.routingEnabled);
    }

    @isTest
    static void supervisorCanRouteResyncAndReassign() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(2);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c one = ServiceRoutingTestFactory.agent(users[0], 5, null);
        Service_Agent__c two = ServiceRoutingTestFactory.agent(users[1], 5, null);
        ServiceRoutingTestFactory.membership(one, q, 3);
        ServiceRoutingTestFactory.membership(two, q, 3);
        Service_Work_Item__c item = ServiceRoutingTestFactory.workItem(q);

        Test.startTest();
        String routeMessage = ServiceSupervisorController.routeNow(q.Id);
        System.assert(routeMessage.contains('Assigned 1'), routeMessage);

        String reassignMessage = ServiceSupervisorController.reassign(item.Id, null, two.Id, 'Balancing the load');
        System.assert(reassignMessage.contains('reassigned'), reassignMessage);

        String resyncMessage = ServiceSupervisorController.resyncCapacity();
        System.assert(resyncMessage.contains('Capacity recalculated'), resyncMessage);
        Test.stopTest();

        System.assertEquals(two.Id, [SELECT Assigned_Agent__c FROM Service_Work_Item__c WHERE Id = :item.Id].Assigned_Agent__c);
    }

    @isTest
    static void supervisorAgentPickerScopesToTheQueue() {
        ServiceRoutingTestFactory.stubAll();
        List<User> users = ServiceRoutingTestFactory.createUsers(2);
        Service_Queue__c q = ServiceRoutingTestFactory.queue('CUSTOMER_SERVICE', 'Least Active');
        Service_Agent__c member = ServiceRoutingTestFactory.agent(users[0], 5, null);
        ServiceRoutingTestFactory.agent(users[1], 5, null); // not a member of this queue
        ServiceRoutingTestFactory.membership(member, q, 3);

        Test.startTest();
        List<Map<String, String>> scoped = ServiceSupervisorController.getAvailableAgents(q.Id);
        List<Map<String, String>> all = ServiceSupervisorController.getAvailableAgents(null);
        Test.stopTest();

        System.assertEquals(1, scoped.size(), 'Only queue members should be offered');
        System.assertEquals(2, all.size());
    }
}
