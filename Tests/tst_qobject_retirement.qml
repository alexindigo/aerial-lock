import QtQuick
import QtTest

TestCase {
    id: test
    name: "QObjectRetirementNotification"
    when: windowShown
    property QtObject receiver: null
    property int retirementNotifications: 0
    onReceiverChanged: {
        if (receiver === null) retirementNotifications++
    }
    Component { id: factory; QtObject {} }
    function test_typed_property_observes_actual_receiver_destruction() {
        var instance = factory.createObject(test)
        receiver = instance
        var before = retirementNotifications
        instance.destroy()
        tryCompare(test, "receiver", null, 1000)
        compare(retirementNotifications, before + 1)
    }
}
