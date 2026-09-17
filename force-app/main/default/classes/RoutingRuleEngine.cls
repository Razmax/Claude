/**
 * Turns a source record (Case, Lead, a custom Credit Request, anything) into a routing
 * decision using Service_Routing_Rule__mdt.
 *
 * Rules are evaluated in Order ascending. Each rule supports up to two ANDed conditions
 * against fields on the record, including parent fields via dot notation
 * (for example Account.Industry), as long as the caller queried them.
 *
 * This is deliberately simple: two conditions cover the overwhelming majority of real
 * routing rules, and anything more complex belongs in a Flow that calls the routing
 * action directly with an explicit queue.
 */
public with sharing class RoutingRuleEngine {
    private static List<Service_Routing_Rule__mdt> cachedRules;

    public static List<Service_Routing_Rule__mdt> rules() {
        if (cachedRules == null) {
            cachedRules = [
                SELECT DeveloperName, MasterLabel, Active__c, Order__c, Source_Object__c, Channel__c,
                       Field_1_API_Name__c, Operator_1__c, Value_1__c,
                       Field_2_API_Name__c, Operator_2__c, Value_2__c,
                       Target_Queue__c, Priority__c, Capacity_Weight__c, Required_Skills__c,
                       SLA_Minutes__c, Stop_Processing__c
                FROM Service_Routing_Rule__mdt
                WHERE Active__c = true
                ORDER BY Order__c NULLS LAST, DeveloperName
            ];
        }
        return cachedRules;
    }

    /**
     * @param record  the source record, with every field referenced by a rule already queried
     * @param channel optional channel filter supplied by the caller
     */
    public static RoutingDecision evaluate(SObject record, String channel) {
        RoutingDecision decision = new RoutingDecision();
        if (record == null) {
            return decision;
        }
        String objectType = String.valueOf(record.getSObjectType());

        for (Service_Routing_Rule__mdt rule : rules()) {
            if (String.isNotBlank(rule.Source_Object__c) && !rule.Source_Object__c.equalsIgnoreCase(objectType)) {
                continue;
            }
            if (String.isNotBlank(rule.Channel__c) && String.isNotBlank(channel)
                && !rule.Channel__c.equalsIgnoreCase(channel)) {
                continue;
            }
            if (!conditionPasses(record, rule.Field_1_API_Name__c, rule.Operator_1__c, rule.Value_1__c)) {
                continue;
            }
            if (!conditionPasses(record, rule.Field_2_API_Name__c, rule.Operator_2__c, rule.Value_2__c)) {
                continue;
            }
            applyRule(decision, rule);
            if (rule.Stop_Processing__c != false) {
                break;
            }
        }
        return decision;
    }

    private static void applyRule(RoutingDecision decision, Service_Routing_Rule__mdt rule) {
        if (String.isNotBlank(rule.Target_Queue__c)) {
            decision.queueDeveloperName = rule.Target_Queue__c.trim();
        }
        if (rule.Priority__c != null) {
            decision.priority = rule.Priority__c;
        }
        if (rule.Capacity_Weight__c != null) {
            decision.capacityWeight = rule.Capacity_Weight__c;
        }
        if (String.isNotBlank(rule.Required_Skills__c)) {
            decision.requiredSkills = rule.Required_Skills__c.trim();
        }
        if (rule.SLA_Minutes__c != null) {
            decision.slaMinutes = rule.SLA_Minutes__c;
        }
        decision.matchedRule = rule.DeveloperName;
    }

    @TestVisible
    private static Boolean conditionPasses(SObject record, String fieldPath, String operator, String expected) {
        if (String.isBlank(fieldPath)) {
            return true; // an empty condition slot is not a filter
        }
        Object actual = readField(record, fieldPath);
        String actualText = actual == null ? null : String.valueOf(actual);
        String op = String.isBlank(operator) ? 'Equals' : operator;

        if (op == 'Is Null') {
            return actual == null || String.isBlank(actualText);
        }
        if (op == 'Is Not Null') {
            return actual != null && String.isNotBlank(actualText);
        }
        if (actual == null) {
            // Every remaining operator needs a value to compare against.
            return op == 'Not Equals' && String.isNotBlank(expected);
        }
        if (op == 'Equals') {
            return actualText.equalsIgnoreCase(expected);
        }
        if (op == 'Not Equals') {
            return !actualText.equalsIgnoreCase(expected);
        }
        if (op == 'Contains') {
            return expected != null && actualText.containsIgnoreCase(expected);
        }
        if (op == 'Starts With') {
            return expected != null && actualText.startsWithIgnoreCase(expected);
        }
        if (op == 'In') {
            for (String candidate : String.isBlank(expected) ? new List<String>() : expected.split(';')) {
                if (actualText.equalsIgnoreCase(candidate.trim())) {
                    return true;
                }
            }
            return false;
        }
        if (op == 'Greater Than' || op == 'Less Than') {
            Integer comparison = compare(actual, actualText, expected);
            if (comparison == null) {
                return false;
            }
            return op == 'Greater Than' ? comparison > 0 : comparison < 0;
        }
        return false;
    }

    /** Numeric and date aware comparison, falling back to case-insensitive text. */
    private static Integer compare(Object actual, String actualText, String expected) {
        if (String.isBlank(expected)) {
            return null;
        }
        if (actual instanceof Decimal || actual instanceof Integer || actual instanceof Double || actual instanceof Long) {
            try {
                Decimal left = Decimal.valueOf(actualText);
                Decimal right = Decimal.valueOf(expected.trim());
                return left == right ? 0 : (left > right ? 1 : -1);
            } catch (Exception e) {
                return null;
            }
        }
        if (actual instanceof Datetime) {
            try {
                Datetime left = (Datetime) actual;
                Datetime right = Datetime.valueOfGmt(expected.trim().replace('T', ' ').replace('Z', ''));
                return left == right ? 0 : (left > right ? 1 : -1);
            } catch (Exception e) {
                return null;
            }
        }
        if (actual instanceof Date) {
            try {
                Date left = (Date) actual;
                Date right = Date.valueOf(expected.trim());
                return left == right ? 0 : (left > right ? 1 : -1);
            } catch (Exception e) {
                return null;
            }
        }
        return actualText.toLowerCase().compareTo(expected.trim().toLowerCase());
    }

    /** Reads Field__c or Parent__r.Field__c from an already-queried record. */
    @TestVisible
    private static Object readField(SObject record, String fieldPath) {
        try {
            if (!fieldPath.contains('.')) {
                return record.get(fieldPath.trim());
            }
            List<String> parts = fieldPath.trim().split('\\.');
            SObject current = record;
            for (Integer i = 0; i < parts.size() - 1; i++) {
                String relationship = parts[i];
                // Tolerate both Account.Name and Account__r.Name style paths.
                if (relationship.endsWithIgnoreCase('__c')) {
                    relationship = relationship.removeEndIgnoreCase('__c') + '__r';
                }
                current = current.getSObject(relationship);
                if (current == null) {
                    return null;
                }
            }
            return current.get(parts[parts.size() - 1]);
        } catch (Exception e) {
            // A rule pointing at a field that was not queried should skip, not explode.
            System.debug(LoggingLevel.WARN, 'Routing rule field not readable: ' + fieldPath);
            return null;
        }
    }

    @TestVisible
    private static void overrideRules(List<Service_Routing_Rule__mdt> testRules) {
        cachedRules = testRules;
    }
}
