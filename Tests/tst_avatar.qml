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
            var image = findByPredicate(a, function (it) { return it.sourceSize !== undefined })
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
            var plate = findByPredicate(a, function (it) {
                return it && it.radius !== undefined && it.color !== undefined && it.visible
            })
            verify(plate !== null, "initials plate not found")
            compare(plate.radius, 20, "plate follows the normalized radius")
            compare(a.initials, "TU")
        }

        function test_image_mask_shape_contract() {
            // The mask's shape input must follow the normalized radius —
            // independent of whether the image decodes. (The pixel masking
            // itself is Qt's OpacityMask; the contract we own is the shape.)
            var a = createTemporaryObject(avatarComponent, root,
                                          { "loginName": "Test User", "cornerRadius": 12,
                                            "source": "/nonexistent-d44-fixture" })
            var mask = findMask(a)
            verify(mask !== null, "image mask not found")
            compare(mask.radius, 12, "mask follows the normalized radius")
            verify(mask.radius !== mask.width / 2, "mask is not circular under cornerRadius")
        }

        function test_person_fallback_no_name() {
            var a = createTemporaryObject(avatarComponent, root, { "loginName": "", "cornerRadius": 24 })
            compare(a.initials, "")
            compare(a.effectiveRadius, 24)
        }

        function findMask(item) {
            // The image mask is the invisible layer source Rectangle.
            for (var i = 0; i < item.children.length; i++) {
                var c = item.children[i]
                if (c && c.visible === false && c.radius !== undefined && c.width === item.width)
                    return c
                var nested = findMask(c)
                if (nested)
                    return nested
            }
            return null
        }

        function findByPredicate(item, pred) {
            for (var i = 0; i < item.children.length; i++) {
                var c = item.children[i]
                if (pred(c))
                    return c
                var nested = findByPredicate(c, pred)
                if (nested)
                    return nested
            }
            return null
        }
    }
}
