import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../core/config/app_config.dart';

final authStateProvider = StreamProvider<User?>((ref) {
  return FirebaseAuth.instance.userChanges();
});

class AuthController {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  late final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: const ['email', 'profile'],
    serverClientId: AppConfig.googleWebClientId.isNotEmpty
        ? AppConfig.googleWebClientId
        : null,
  );

  Future<User?> signInWithGoogle() async {
    if (AppConfig.googleWebClientId.isEmpty) {
      throw FirebaseAuthException(
        code: 'missing-web-client-id',
        message:
            'Brak AURORA_GOOGLE_WEB_CLIENT_ID. Firebase Console → Authentication → Google → Web client ID.',
      );
    }

    final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
    if (googleUser == null) return null;

    final GoogleSignInAuthentication googleAuth =
        await googleUser.authentication;

    if (googleAuth.idToken == null || googleAuth.idToken!.isEmpty) {
      throw FirebaseAuthException(
        code: 'missing-id-token',
        message:
            'Google nie zwróciło idToken. Sprawdź Web Client ID w Firebase / Google Cloud.',
      );
    }

    final AuthCredential credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final UserCredential userCredential =
        await _auth.signInWithCredential(credential);
    final user = userCredential.user;
    if (user == null) return null;

    final googleProfile = userCredential.additionalUserInfo?.profile;
    final profilePhoto = googleProfile?['picture'];
    final profileName = googleProfile?['name'];
    final googlePhoto =
        googleUser.photoUrl ?? (profilePhoto is String ? profilePhoto : null);
    final googleName =
        googleUser.displayName ?? (profileName is String ? profileName : null);

    if ((user.photoURL == null || user.photoURL!.isEmpty) &&
        googlePhoto != null &&
        googlePhoto.isNotEmpty) {
      await user.updatePhotoURL(googlePhoto);
    }
    if ((user.displayName == null || user.displayName!.isEmpty) &&
        googleName != null &&
        googleName.isNotEmpty) {
      await user.updateDisplayName(googleName);
    }
    await user.reload();
    return _auth.currentUser;
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
  }

  /// Returns a Google access token with [AppConfig.youtubeReadonlyScope], or
  /// null when the user is signed out or declined the extra permission.
  Future<String?> youtubeAccessToken() async {
    var account = _googleSignIn.currentUser;
    account ??= await _googleSignIn.signInSilently();
    if (account == null) return null;

    final granted = await _googleSignIn.requestScopes(
      [AppConfig.youtubeReadonlyScope],
    );
    if (!granted) return null;

    account = _googleSignIn.currentUser ?? account;
    final auth = await account.authentication;
    return auth.accessToken;
  }
}

final authControllerProvider = Provider((ref) => AuthController());
