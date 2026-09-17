/**
 * Queries a source record with exactly the fields the active routing rules need.
 *
 * This is what lets an admin add a rule on Case.Reason without anyone editing Apex: the
 * field list is derived from the rules themselves at runtime.
 */
public with sharing class SourceRecordLoader {

    public static SObject load(Id recordId) {
        if (recordId == null) {
            return null;
        }
        Schema.SObjectType sobjType = recordId.getSObjectType();
        String objectName = String.valueOf(sobjType);
        Set<String> fields = new Set<String>{'Id'};
        fields.addAll(ruleFields(objectName, sobjType));
        fields.addAll(commonFields(sobjType));

        String soql = 'SELECT ' + String.join(new List<String>(fields), ', ')
            + ' FROM ' + objectName + ' WHERE Id = :recordId LIMIT 1';
        try {
            List<SObject> records = Database.query(soql);
            return records.isEmpty() ? null : records[0];
        } catch (Exception e) {
            // A rule pointing at an unreadable field must not stop work from being created.
            System.debug(LoggingLevel.WARN, 'Source record query failed, retrying with Id only: ' + e.getMessage());
            List<SObject> fallback = Database.query(
                'SELECT Id FROM ' + objectName + ' WHERE Id = :recordId LIMIT 1');
            return fallback.isEmpty() ? null : fallback[0];
        }
    }

    /** Field paths referenced by active rules for this object, filtered to what really exists. */
    private static Set<String> ruleFields(String objectName, Schema.SObjectType sobjType) {
        Set<String> fields = new Set<String>();
        for (Service_Routing_Rule__mdt rule : RoutingRuleEngine.rules()) {
            if (String.isNotBlank(rule.Source_Object__c) && !rule.Source_Object__c.equalsIgnoreCase(objectName)) {
                continue;
            }
            addIfValid(fields, rule.Field_1_API_Name__c, sobjType);
            addIfValid(fields, rule.Field_2_API_Name__c, sobjType);
        }
        return fields;
    }

    /** Descriptive fields we always want on the work item if the object has them. */
    private static Set<String> commonFields(Schema.SObjectType sobjType) {
        Set<String> fields = new Set<String>();
        Map<String, Schema.SObjectField> describe = sobjType.getDescribe().fields.getMap();
        for (String candidate : new List<String>{'Subject', 'Name', 'CaseNumber', 'AccountId', 'ContactId', 'Priority'}) {
            Schema.SObjectField f = describe.get(candidate.toLowerCase());
            if (f != null && f.getDescribe().isAccessible()) {
                fields.add(candidate);
            }
        }
        return fields;
    }

    private static void addIfValid(Set<String> fields, String path, Schema.SObjectType sobjType) {
        if (String.isBlank(path)) {
            return;
        }
        String trimmed = path.trim();
        if (trimmed.contains('.')) {
            // Relationship path - let SOQL validate it, but only if the first hop looks real.
            fields.add(trimmed);
            return;
        }
        Schema.SObjectField field = sobjType.getDescribe().fields.getMap().get(trimmed.toLowerCase());
        if (field != null && field.getDescribe().isAccessible()) {
            fields.add(trimmed);
        }
    }
}
