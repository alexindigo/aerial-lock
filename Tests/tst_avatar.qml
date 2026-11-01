import QtQuick
import QtTest
import "../Modules/Lock" as LockModule

// d44 phase 2: Avatar shape contract. The cornerRadius input is normalized
// once and applied identically to the image mask, the initials plate and
// the drawn person fallback; the default stays circular.
Item {
    id: root
    width: 400
    height: 400

    Component {
        id: avatarComponent
        LockModule.Avatar {
            width: 96
            height: 96
            diameter: 96
        }
    }

    TestCase {
        id: avatarCase
        name: "AvatarShape"
        when: windowShown

        function test_decode_follows_display_size() {
            var path = Qt.resolvedUrl("fixtures/avatar-large.svg").toString().replace(/^file:\/\//, "")
            var a = createTemporaryObject(avatarComponent, root, { "source": path })
            var image = findChild(a, "avatarImage")
            verify(image !== null)
            tryCompare(image, "status", Image.Ready)
            compare(image.sourceSize.width, Math.ceil(a.width * image.Screen.devicePixelRatio))
            compare(image.sourceSize.height, Math.ceil(a.height * image.Screen.devicePixelRatio))
            a.width = 48
            a.height = 72
            tryCompare(image, "sourceSize", Qt.size(Math.ceil(48 * image.Screen.devicePixelRatio),
                                                   Math.ceil(72 * image.Screen.devicePixelRatio)))
        }

        function test_default_is_circular() {
            var a = createTemporaryObject(avatarComponent, root, { "loginName": "Test User" })
            compare(a.effectiveRadius, a.width / 2, "default remains circular")
            verify(a.visible !== false)
        }

        function test_corner_radius_normalized_once() {
            var a = createTemporaryObject(avatarComponent, root, { "loginName": "Test User", "cornerRadius": 16 })
            compare(a.effectiveRadius, 16)
            compare(a.cornerRadius, 16)
        }

        function test_initials_fallback_shape() {
            var a = createTemporaryObject(avatarComponent, root, { "loginName": "Test User", "cornerRadius": 20 })
            // Missing image -> initials plate; its plate radius must follow.
            var plate = findChild(a, "avatarFallbackPlate")
            verify(plate !== null, "initials plate not found")
            verify(plate.visible, "initials fallback is visible without an image")
            compare(plate.radius, 20, "plate follows the normalized radius")
            compare(a.initials, "TU")
        }

        function test_image_mask_shape_contract() {
            // The mask's shape input must follow the normalized radius —
            // use a real fixture so asynchronous image errors cannot escape
            // into another test. The pixel masking itself is Qt's OpacityMask;
            // the contract we own is the shape.
            var path = Qt.resolvedUrl("fixtures/avatar-large.svg").toString().replace(/^file:\/\//, "")
            var a = createTemporaryObject(avatarComponent, root,
                                          { "loginName": "Test User", "cornerRadius": 12,
                                            "source": path })
            var image = findChild(a, "avatarImage")
            verify(image !== null)
            tryCompare(image, "status", Image.Ready)
            var mask = findChild(a, "avatarMaskCircle")
            verify(mask !== null, "image mask not found")
            var plate = findChild(a, "avatarFallbackPlate")
            verify(plate !== null)
            verify(!plate.visible, "decoded image hides the fallback plate")
            verify(mask !== plate, "mask identity does not depend on plate visibility")
            compare(mask.radius, 12, "mask follows the normalized radius")
            verify(mask.radius !== mask.width / 2, "mask is not circular under cornerRadius")
        }

        function test_person_fallback_no_name() {
            var a = createTemporaryObject(avatarComponent, root, { "loginName": "", "cornerRadius": 24 })
            compare(a.initials, "")
            compare(a.effectiveRadius, 24)
        }

    }
}
