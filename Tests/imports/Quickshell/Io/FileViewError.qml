pragma Singleton
import QtQml

QtObject {
    enum Error { FileNotFound }
    function toString(error) { return "test file error " + error }
}
