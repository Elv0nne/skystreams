package android.os;

/**
 * Android's parcelable marker. Bundles and intents carry such objects as they are, never flattened, so
 * nothing calls writeToParcel (framework-gen adds it, as Android declares it).
 */
public interface Parcelable {
    int CONTENTS_FILE_DESCRIPTOR = 0x0001;
    int PARCELABLE_WRITE_RETURN_VALUE = 0x0001;

    int describeContents();
}
