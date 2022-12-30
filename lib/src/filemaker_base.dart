import 'dart:io';
import 'dart:convert';
import 'package:dart_appwrite/dart_appwrite.dart' as appwrite;
import 'package:dart_appwrite/models.dart' as models;
import 'package:dart_appwrite/models.dart';
import 'package:dio/dio.dart';
import 'package:intl/intl.dart';

enum Method { post, patch }

String? filemakerAccountName;
String? filemakerPassword;
String? filemakerFilename;
String? filemakerDataApiUrl;
String? variablesCollectionId;
String? targetProjectId;

String token = "";
String tokenDocumentId = "";
int epoch = 0;
int now = DateTime.now().millisecondsSinceEpoch;

Future getToken(
    {required appwrite.Database database, bool forceRenew = false}) async {
  try {
    models.DocumentList documentList = await database
        .listDocuments(collectionId: variablesCollectionId!, queries: [
      appwrite.Query.equal('key', '$targetProjectId.token.$filemakerFilename')
    ]);
    if (documentList.total != 0) {
      token = documentList.documents.first.data['value'];
      epoch = documentList.documents.first.data['epoch'];
      tokenDocumentId = documentList.documents.first.data['\$id'];
    } else {
      epoch = 0;
      Document document = await database.createDocument(
          collectionId: variablesCollectionId!,
          documentId: "unique()",
          data: {
            "key": '$targetProjectId.token.$filemakerFilename',
            "value": "invalid",
            "epoch": "0"
          });
      tokenDocumentId = document.$id;
    }
  } on appwrite.AppwriteException catch (e) {
    return e;
  } catch (e) {
    return e;
  }

  if (now - epoch <= 14 * 60 * 1000 && !forceRenew) {
    return token;
  }
  // Configure dio request to communicate with Filemaker Data API
  dynamic requestInterceptor(
      RequestOptions options, RequestInterceptorHandler handler) async {
    String basicAuth = 'Basic ' +
        base64Encode(utf8.encode('$filemakerAccountName:$filemakerPassword'));
    options.headers.addAll({"Authorization": basicAuth});
    options.headers.addAll({"Content-Type": 'application/json'});
    options.baseUrl = filemakerDataApiUrl!;
    return handler.next(options);
  }

  // Configure dio error interceptor to postpone treatment if
  // Optimus didn't response correctly
  dynamic errorInterceptor(
      DioError error, ErrorInterceptorHandler handler) async {
    stderr.write('$error');
    stderr.write(error.message);
    stderr.write('${error.response}');
    stderr.write('${error.requestOptions.data}');
    stderr.write(error.requestOptions.path);
    stderr.write(error.requestOptions.baseUrl);
    stderr.write('${error.requestOptions.uri}');
    stderr.write('${error.requestOptions.extra}');
    stderr.write('${error.requestOptions.queryParameters}');
    handler.next(error);
  }

  try {
    Dio dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) => requestInterceptor(options, handler),
        onError: (error, handler) => errorInterceptor(error, handler),
      ));
    Response response =
        await dio.post("/databases/$filemakerFilename/sessions");
    dio.close();
    var _token = response.data['response']['token'];
    if (_token == null || _token is! String) {
      return null;
    }
    DateFormat formatter;
    formatter = DateFormat('dd/MM/yyyy HH:mm:ss');
    String timestamp =
        formatter.format(DateTime.fromMillisecondsSinceEpoch(now));
    await database.updateDocument(
      collectionId: variablesCollectionId!,
      documentId: tokenDocumentId,
      data: {
        "value": _token,
        "epoch": now,
        "comments": timestamp,
      },
    );
    token = _token;
    return _token;
  } catch (error) {
    stderr.write('$error');
    return null;
  }
}

Future refreshToken({
  required appwrite.Database database,
  required dynamic envVars,
}) async {
  filemakerAccountName = envVars['FILEMAKER_ACCOUNT_NAME'];
  filemakerPassword = envVars['FILEMAKER_PASSWORD'];
  filemakerFilename = envVars['FILEMAKER_FILENAME'];
  filemakerDataApiUrl = envVars['FILEMAKER_DATA_API_URL'];
  variablesCollectionId = envVars['VARIABLES_COLLECTION_ID'];
  targetProjectId = envVars['TARGET_PROJECT_ID'];

  // Get token
  var getTokenResult = await getToken(database: database) ?? "";
  if (token.isEmpty) {
    token = await getToken(database: database, forceRenew: true) ?? "";
  }
  if (token.isEmpty) {
    return Exception('Unable to get a new token $getTokenResult');
  }
  return token;
}

Future createOrUpdateOptimusRecord({
  required appwrite.Database database,
  required String layoutName,
  required var data,
  required Method method,
  String? recordId,
  required dynamic envVars,
}) async {
  filemakerAccountName = envVars['FILEMAKER_ACCOUNT_NAME'];
  filemakerPassword = envVars['FILEMAKER_PASSWORD'];
  filemakerFilename = envVars['FILEMAKER_FILENAME'];
  filemakerDataApiUrl = envVars['FILEMAKER_DATA_API_URL'];
  variablesCollectionId = envVars['VARIABLES_COLLECTION_ID'];
  targetProjectId = envVars['TARGET_PROJECT_ID'];

  // Get token
  var getTokenResult = await getToken(database: database) ?? "";
  if (token.isEmpty) {
    token = await getToken(database: database, forceRenew: true) ?? "";
  }
  if (token.isEmpty) {
    return Exception('Unable to get a new token $getTokenResult');
  }
  // Configure dio request to communicate with Filemaker Data API
  dynamic requestInterceptor(
      RequestOptions options, RequestInterceptorHandler handler) async {
    String bearerAuth = 'Bearer $token';
    options.headers.addAll({"Authorization": bearerAuth});
    options.headers.addAll({"Content-Type": 'application/json'});
    options.baseUrl = filemakerDataApiUrl!;
    // Consider only server error >= 500 as errors
    options.validateStatus = (status) {
      return status != null && status < 600;
    };
    return handler.next(options);
  }

  // Configure dio error interceptor to exit with error
  dynamic errorInterceptor(
      DioError error, ErrorInterceptorHandler handler) async {
    stderr.write('error: $error');
    stderr.write('message: ${error.message}');
    stderr.write('response: ${error.response}');
    stderr.write('data: ${error.requestOptions.data}');
    stderr.write('path: ${error.requestOptions.path}');
    stderr.write('baseUrl: ${error.requestOptions.baseUrl}');
    stderr.write('uri: ${error.requestOptions.uri}');
    stderr.write('extra: ${error.requestOptions.extra}');
    stderr.write('queryParameters: ${error.requestOptions.queryParameters}');
    handler.next(error);
  }

  try {
    Dio dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) => requestInterceptor(options, handler),
        onError: (error, handler) => errorInterceptor(error, handler),
      ));
    Response response;

    response = (method == Method.post)
        ? await dio.post(
            "/databases/$filemakerFilename/layouts/$layoutName/records",
            data: data,
          )
        : await dio.patch(
            "/databases/$filemakerFilename/layouts/$layoutName/records/$recordId",
            data: data,
          );
    var code = response.data['messages'][0]['code'];
    if (code == "952") {
      // Token is not valid, force a new token request
      token = await getToken(database: database, forceRenew: true) ?? "";
      if (token.isEmpty) return Exception('Unable to get a new token');
      response = (method == Method.post)
          ? await dio.post(
              "/databases/$filemakerFilename/layouts/$layoutName/records",
              data: data,
            )
          : await dio.patch(
              "/databases/$filemakerFilename/layouts/$layoutName/records/$recordId",
              data: data,
            );
    }
    dio.close();
    return response.data;
  } catch (error) {
    return error;
  }
}

Future find({
  required appwrite.Database database,
  required String layoutName,
  required var query,
  required dynamic envVars,
}) async {
  filemakerAccountName = envVars['FILEMAKER_ACCOUNT_NAME'];
  filemakerPassword = envVars['FILEMAKER_PASSWORD'];
  filemakerFilename = envVars['FILEMAKER_FILENAME'];
  filemakerDataApiUrl = envVars['FILEMAKER_DATA_API_URL'];
  variablesCollectionId = envVars['VARIABLES_COLLECTION_ID'];
  targetProjectId = envVars['TARGET_PROJECT_ID'];

  // Get token
  var getTokenResult = await getToken(database: database) ?? "";
  if (token.isEmpty) {
    token = await getToken(database: database, forceRenew: true) ?? "";
  }
  if (token.isEmpty) {
    return Exception('Unable to get a new token $getTokenResult');
  }
  // Configure dio request to communicate with Filemaker Data API
  dynamic requestInterceptor(
      RequestOptions options, RequestInterceptorHandler handler) async {
    String bearerAuth = 'Bearer $token';
    options.headers.addAll({"Authorization": bearerAuth});
    options.headers.addAll({"Content-Type": 'application/json'});
    options.baseUrl = filemakerDataApiUrl!;
    // Consider only server error >= 500 as errors
    options.validateStatus = (status) {
      return status != null && status < 600;
    };
    return handler.next(options);
  }

  // Configure dio error interceptor to exit with error
  dynamic errorInterceptor(
      DioError error, ErrorInterceptorHandler handler) async {
    stderr.write('error: $error');
    stderr.write('message: ${error.message}');
    stderr.write('response: ${error.response}');
    stderr.write('data: ${error.requestOptions.data}');
    stderr.write('path: ${error.requestOptions.path}');
    stderr.write('baseUrl: ${error.requestOptions.baseUrl}');
    stderr.write('uri: ${error.requestOptions.uri}');
    stderr.write('extra: ${error.requestOptions.extra}');
    stderr.write('queryParameters: ${error.requestOptions.queryParameters}');
    handler.next(error);
  }

  try {
    Dio dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) => requestInterceptor(options, handler),
        onError: (error, handler) => errorInterceptor(error, handler),
      ));
    Response response;

    response = await dio.post(
      "/databases/$filemakerFilename/layouts/$layoutName/_find",
      data: query,
    );

    var code = response.data['messages'][0]['code'];
    if (code == "952") {
      // Token is not valid, force a new token request
      token = await getToken(database: database, forceRenew: true) ?? "";
      if (token.isEmpty) return Exception('Unable to get a new token');
      response = response = await dio.post(
        "/databases/$filemakerFilename/layouts/$layoutName/_find",
        data: query,
      );
    }
    dio.close();
    return response.data;
  } catch (error) {
    return error;
  }
}

Future runScript({
  required appwrite.Database database,
  required String layoutName,
  required String scriptName,
  required bool waitResponse,
  String? parameter,
  required dynamic envVars,
}) async {
  filemakerAccountName = envVars['FILEMAKER_ACCOUNT_NAME'];
  filemakerPassword = envVars['FILEMAKER_PASSWORD'];
  filemakerFilename = envVars['FILEMAKER_FILENAME'];
  filemakerDataApiUrl = envVars['FILEMAKER_DATA_API_URL'];
  variablesCollectionId = envVars['VARIABLES_COLLECTION_ID'];
  targetProjectId = envVars['TARGET_PROJECT_ID'];

  // Get token
  token = await getToken(database: database) ?? "";
  if (token.isEmpty) {
    token = await getToken(database: database, forceRenew: true) ?? "";
  }
  if (token.isEmpty) {
    return Exception('Unable to get a new token');
  }
  // Configure dio request to communicate with Filemaker Data API
  dynamic requestInterceptor(
      RequestOptions options, RequestInterceptorHandler handler) async {
    String bearerAuth = 'Bearer $token';
    options.headers.addAll({"Authorization": bearerAuth});
    options.headers.addAll({"Content-Type": 'application/json'});
    options.baseUrl = filemakerDataApiUrl!;
    // Consider only server error >= 500 as errors
    options.validateStatus = (status) {
      return status != null && status < 600;
    };
    return handler.next(options);
  }

  // Configure dio error interceptor to exit with error
  dynamic errorInterceptor(
      DioError error, ErrorInterceptorHandler handler) async {
    stderr.write('$error');
    stderr.write(error.message);
    stderr.write('${error.response}');
    stderr.write('${error.requestOptions.data}');
    stderr.write(error.requestOptions.path);
    stderr.write(error.requestOptions.baseUrl);
    stderr.write('${error.requestOptions.uri}');
    stderr.write('${error.requestOptions.extra}');
    stderr.write('${error.requestOptions.queryParameters}');
    handler.next(error);
  }

  try {
    Dio dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) => requestInterceptor(options, handler),
        onError: (error, handler) => errorInterceptor(error, handler),
      ));
    Response response;

    String url =
        "/databases/$filemakerFilename/layouts/$layoutName/script/$scriptName";
    if (parameter != null) {
      url += "?script.param=$parameter";
    }
    if (waitResponse) {
      response = await dio.get(url);

      var code = response.data['messages'][0]['code'];
      if (code == "952") {
        // Token is not valid, force a new token request
        token = await getToken(database: database, forceRenew: true) ?? "";
        if (token.isEmpty) return Exception('Unable to get a new token');
        response = await dio.get(url);
      }
      dio.close();
      return response.data;
    } else {
      dio.get(url).then((response) async {
        var code = response.data['messages'][0]['code'];
        if (code == "952") {
          // Token is not valid, force a new token request
          token = await getToken(database: database, forceRenew: true) ?? "";
          if (token.isEmpty) {
            dio.close();
            return;
          }

          dio.get(url).then((value) {
            dio.close();
            return;
          });
        } else {
          dio.close();
          return;
        }
      });
    }
  } catch (error) {
    return error;
  }
}

Future getRecordWithRecordId({
  required appwrite.Database database,
  required String layoutName,
  required String recordId,
  required dynamic envVars,
}) async {
  filemakerAccountName = envVars['FILEMAKER_ACCOUNT_NAME'];
  filemakerPassword = envVars['FILEMAKER_PASSWORD'];
  filemakerFilename = envVars['FILEMAKER_FILENAME'];
  filemakerDataApiUrl = envVars['FILEMAKER_DATA_API_URL'];
  variablesCollectionId = envVars['VARIABLES_COLLECTION_ID'];
  targetProjectId = envVars['TARGET_PROJECT_ID'];

  // Get token
  token = await getToken(database: database) ?? "";
  if (token.isEmpty) {
    token = await getToken(database: database, forceRenew: true) ?? "";
  }
  if (token.isEmpty) {
    return Exception('Unable to get a new token');
  }
  // Configure dio request to communicate with Filemaker Data API
  dynamic requestInterceptor(
      RequestOptions options, RequestInterceptorHandler handler) async {
    String bearerAuth = 'Bearer $token';
    options.headers.addAll({"Authorization": bearerAuth});
    options.headers.addAll({"Content-Type": 'application/json'});
    options.baseUrl = filemakerDataApiUrl!;
    // Consider only server error >= 500 as errors
    options.validateStatus = (status) {
      return status != null && status < 600;
    };
    return handler.next(options);
  }

  // Configure dio error interceptor to exit with error
  dynamic errorInterceptor(
      DioError error, ErrorInterceptorHandler handler) async {
    stderr.write('$error');
    stderr.write(error.message);
    stderr.write('${error.response}');
    stderr.write('${error.requestOptions.data}');
    stderr.write(error.requestOptions.path);
    stderr.write(error.requestOptions.baseUrl);
    stderr.write('${error.requestOptions.uri}');
    stderr.write('${error.requestOptions.extra}');
    stderr.write('${error.requestOptions.queryParameters}');
    handler.next(error);
  }

  try {
    Dio dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) => requestInterceptor(options, handler),
        onError: (error, handler) => errorInterceptor(error, handler),
      ));
    Response response;

    response = await dio.get(
        "/databases/$filemakerFilename/layouts/$layoutName/records/$recordId");

    var code = response.data['messages'][0]['code'];
    if (code == "952") {
      // Token is not valid, force a new token request
      token = await getToken(database: database, forceRenew: true) ?? "";
      if (token.isEmpty) return Exception('Unable to get a new token');
      response = await dio.get(
          "/databases/$filemakerFilename/layouts/$layoutName/records/$recordId");
    }
    dio.close();
    return response.data;
  } catch (error) {
    return error;
  }
}

Future setGlobals({
  required appwrite.Database database,
  required Map<String, String> globalFields,
  required dynamic envVars,
}) async {
  filemakerAccountName = envVars['FILEMAKER_ACCOUNT_NAME'];
  filemakerPassword = envVars['FILEMAKER_PASSWORD'];
  filemakerFilename = envVars['FILEMAKER_FILENAME'];
  filemakerDataApiUrl = envVars['FILEMAKER_DATA_API_URL'];
  variablesCollectionId = envVars['VARIABLES_COLLECTION_ID'];
  targetProjectId = envVars['TARGET_PROJECT_ID'];

  // Get token
  token = await getToken(database: database) ?? "";
  if (token.isEmpty) {
    token = await getToken(database: database, forceRenew: true) ?? "";
  }
  if (token.isEmpty) {
    return Exception('Unable to get a new token');
  }
  // Configure dio request to communicate with Filemaker Data API
  dynamic requestInterceptor(
      RequestOptions options, RequestInterceptorHandler handler) async {
    String bearerAuth = 'Bearer $token';
    options.headers.addAll({"Authorization": bearerAuth});
    options.headers.addAll({"Content-Type": 'application/json'});
    options.baseUrl = filemakerDataApiUrl!;
    // Consider only server error >= 500 as errors
    options.validateStatus = (status) {
      return status != null && status < 600;
    };
    return handler.next(options);
  }

  // Configure dio error interceptor to exit with error
  dynamic errorInterceptor(
      DioError error, ErrorInterceptorHandler handler) async {
    stderr.write('$error');
    stderr.write(error.message);
    stderr.write('${error.response}');
    stderr.write('${error.requestOptions.data}');
    stderr.write(error.requestOptions.path);
    stderr.write(error.requestOptions.baseUrl);
    stderr.write('${error.requestOptions.uri}');
    stderr.write('${error.requestOptions.extra}');
    stderr.write('${error.requestOptions.queryParameters}');
    handler.next(error);
  }

  try {
    Dio dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) => requestInterceptor(options, handler),
        onError: (error, handler) => errorInterceptor(error, handler),
      ));
    Response response;

    Map<String, dynamic> data = {
      "$filemakerFilename globalFields": globalFields
    };
    print('setting globals: $data');
    response = await dio.patch(
      "/databases/$filemakerFilename/globals",
      data: data,
    );
    print('setting globals response: ${response.data}');
    var code = response.data['messages'][0]['code'];
    if (code == "952") {
      // Token is not valid, force a new token request
      token = await getToken(database: database, forceRenew: true) ?? "";
      if (token.isEmpty) return Exception('Unable to get a new token');
      response = await dio.patch(
        "/databases/$filemakerFilename/globals",
        data: data,
      );
    }
    dio.close();
    return response.data;
  } catch (error) {
    return error;
  }
}
