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
String? databaseId;

String token = "";
String tokenDocumentId = "";
int epoch = 0;
int get now => DateTime.now().millisecondsSinceEpoch;

// Trick to test if repo is well updated
String get getFilemakerAppwriteVersion => '2023-04-27';

Future getToken({
  required appwrite.Databases databases,
  bool forceRenew = false,
  required String process,
  required context,
}) async {
  try {
    context.log(
        'getToken START with current forceRenew: $forceRenew - token: $token');
    models.DocumentList documentList = await databases.listDocuments(
        databaseId: databaseId!,
        collectionId: variablesCollectionId!,
        queries: [
          appwrite.Query.equal(
              'key', '$targetProjectId.token.$filemakerFilename')
        ]);
    context.log('getToken - documentList: ${documentList.documents}');
    if (documentList.total != 0) {
      token = documentList.documents.first.data['value'];
      epoch = documentList.documents.first.data['epoch'];
      tokenDocumentId = documentList.documents.first.data['\$id'];
      context.log('getToken - get token from appwrite: $token');
      context.log('getToken - get epoch from appwrite: $epoch');
      context.log(
          'getToken - get tokenDocumentId from appwrite: $tokenDocumentId');
    } else {
      context.log('getToken - token record not found, create it');
      epoch = 0;
      Document document = await databases.createDocument(
          databaseId: databaseId!,
          collectionId: variablesCollectionId!,
          documentId: "unique()",
          data: {
            "key": '$targetProjectId.token.$filemakerFilename',
            "value": "invalid",
            "epoch": 0
          });
      tokenDocumentId = document.$id;
      context.log(
          'getToken - get tokenDocumentId from appwrite: $tokenDocumentId');
    }
  } on appwrite.AppwriteException catch (e) {
    context.log('getToken - AppwriteException: $e');
    return e;
  } catch (e) {
    context.log('getToken - Exception: $e');
    return e;
  }

  if (now - epoch <= 14 * 60 * 1000 && !forceRenew) {
    // Set timestamp to now to extand token lifetime

    DateFormat formatter;
    formatter = DateFormat('dd/MM/yyyy HH:mm:ss');
    String timestamp =
        formatter.format(DateTime.fromMillisecondsSinceEpoch(now));
    await databases.updateDocument(
      databaseId: databaseId!,
      collectionId: variablesCollectionId!,
      documentId: tokenDocumentId,
      data: {
        "epoch": now,
        "comments": '$timestamp process:$process now:$now',
      },
    );
    context.log('getToken - Extend token $token to $timestamp');

    return token;
  } else {
    context.log('epoch: $epoch');
    context.log('now: $now');
    context.log('now - epoch: ${now - epoch}');
    context
        .log('getToken - Token $token is expired, force a new token request');
  }
  // Configure dio request to communicate with Filemaker Data API
  dynamic requestInterceptor(
      RequestOptions options, RequestInterceptorHandler handler) async {
    String basicAuth = 'Basic ' +
        base64Encode(utf8.encode('$filemakerAccountName:$filemakerPassword'));
    options.headers.addAll({"Authorization": basicAuth});
    options.headers.addAll({"Content-Type": 'application/json'});
    options.baseUrl = filemakerDataApiUrl!;
    context.log('getToken - requestInterceptor options: $options');
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
    context.log('getToken - errorInterceptor error: $error');
    return handler.next(error);
  }

  try {
    Dio dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) => requestInterceptor(options, handler),
        onError: (error, handler) => errorInterceptor(error, handler),
      ));
    context.log('getToken - Sending token request to Filemaker Data API');
    Response response =
        await dio.post("/databases/$filemakerFilename/sessions");
    context.log(
        'getToken - Receiving token response from Filemaker Data API: ${response.data}');
    dio.close();
    var _token = response.data['response']['token'];
    if (_token == null || _token is! String) {
      return null;
    }
    DateFormat formatter;
    formatter = DateFormat('dd/MM/yyyy HH:mm:ss');
    String timestamp =
        formatter.format(DateTime.fromMillisecondsSinceEpoch(now));
    await databases.updateDocument(
      databaseId: databaseId!,
      collectionId: variablesCollectionId!,
      documentId: tokenDocumentId,
      data: {
        "value": _token,
        "epoch": now,
        "comments": timestamp,
      },
    );
    token = _token;
    context.log('getToken - New token $token updated at $timestamp');
    return _token;
  } catch (error) {
    stderr.write('$error');
    return null;
  }
}

Future refreshToken({
  required appwrite.Databases databases,
  required dynamic envVars,
  required context,
}) async {
  filemakerAccountName = envVars['FILEMAKER_ACCOUNT_NAME'];
  filemakerPassword = envVars['FILEMAKER_PASSWORD'];
  filemakerFilename = envVars['FILEMAKER_FILENAME'];
  filemakerDataApiUrl = envVars['FILEMAKER_DATA_API_URL'];
  variablesCollectionId = envVars['VARIABLES_COLLECTION_ID'];
  targetProjectId = envVars['TARGET_PROJECT_ID'];
  databaseId = envVars['DATABASE_ID'];

  // Get token
  var getTokenResult = await getToken(
          databases: databases, process: 'refreshToken 1', context: context) ??
      "";
  if (token.isEmpty) {
    token = await getToken(
          databases: databases,
          forceRenew: true,
          process: 'refreshToken 2',
          context: context,
        ) ??
        "";
  }
  if (token.isEmpty) {
    return Exception('Unable to get a new token $getTokenResult');
  }
  return token;
}

Future createOrUpdateOptimusRecord({
  required appwrite.Databases databases,
  required String layoutName,
  required var data,
  required Method method,
  String? recordId,
  required dynamic envVars,
  required context,
}) async {
  filemakerAccountName = envVars['FILEMAKER_ACCOUNT_NAME'];
  filemakerPassword = envVars['FILEMAKER_PASSWORD'];
  filemakerFilename = envVars['FILEMAKER_FILENAME'];
  filemakerDataApiUrl = envVars['FILEMAKER_DATA_API_URL'];
  variablesCollectionId = envVars['VARIABLES_COLLECTION_ID'];
  targetProjectId = envVars['TARGET_PROJECT_ID'];
  databaseId = envVars['DATABASE_ID'];

  // Get token
  var getTokenResult = await getToken(
        databases: databases,
        process: 'createOrUpdateOptimusRecord',
        context: context,
      ) ??
      "";
  context.log(
      'createOrUpdateOptimusRecord - getTokenResult: $getTokenResult - token: $token');
  if (token.isEmpty) {
    context.log('createOrUpdateOptimusRecord - token is empty, forceRenew');
    token = await getToken(
          databases: databases,
          forceRenew: true,
          process: 'createOrUpdateOptimusRecord',
          context: context,
        ) ??
        "";
  }
  if (token.isEmpty) {
    context.log(
        'createOrUpdateOptimusRecord - token is STILL empty, return Exception');
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
      return status != null && status < 500;
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
    context.log(
        'createOrUpdateOptimusRecord - errorInterceptor -  ${error.response} -  ${error.requestOptions.data}');
    return handler.next(error);
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
      context.log(
          'createOrUpdateOptimusRecord - errorInterceptor -  ${response.data} -  forceRenew');
      token = await getToken(
            databases: databases,
            forceRenew: true,
            process: 'createOrUpdateOptimusRecord',
            context: context,
          ) ??
          "";
      if (token.isEmpty) {
        context.log(
            'createOrUpdateOptimusRecord - errorInterceptor - token is empty, return Exception');
        return Exception('Unable to get a new token');
      }
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
  required appwrite.Databases databases,
  required String layoutName,
  required var query,
  required dynamic envVars,
  required context,
}) async {
  filemakerAccountName = envVars['FILEMAKER_ACCOUNT_NAME'];
  filemakerPassword = envVars['FILEMAKER_PASSWORD'];
  filemakerFilename = envVars['FILEMAKER_FILENAME'];
  filemakerDataApiUrl = envVars['FILEMAKER_DATA_API_URL'];
  variablesCollectionId = envVars['VARIABLES_COLLECTION_ID'];
  targetProjectId = envVars['TARGET_PROJECT_ID'];
  databaseId = envVars['DATABASE_ID'];

  // Get token
  var getTokenResult = await getToken(
        databases: databases,
        process: 'find 1',
        context: context,
      ) ??
      "";
  if (token.isEmpty) {
    context.log('find - token is empty, forceRenew');
    token = await getToken(
          databases: databases,
          forceRenew: true,
          process: 'find 2',
          context: context,
        ) ??
        "";
  }
  if (token.isEmpty) {
    context.log('find - token is STILL empty, return Exception');
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
      return status != null && status < 500;
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
    context.log(
        'find - errorInterceptor -  ${error.response} -  ${error.message}');
    return handler.next(error);
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
      token = await getToken(
            databases: databases,
            forceRenew: true,
            process: 'find 3',
            context: context,
          ) ??
          "";
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
  required appwrite.Databases databases,
  required String layoutName,
  required String scriptName,
  required bool waitResponse,
  String? parameter,
  required dynamic envVars,
  required context,
}) async {
  filemakerAccountName = envVars['FILEMAKER_ACCOUNT_NAME'];
  filemakerPassword = envVars['FILEMAKER_PASSWORD'];
  filemakerFilename = envVars['FILEMAKER_FILENAME'];
  filemakerDataApiUrl = envVars['FILEMAKER_DATA_API_URL'];
  variablesCollectionId = envVars['VARIABLES_COLLECTION_ID'];
  targetProjectId = envVars['TARGET_PROJECT_ID'];
  databaseId = envVars['DATABASE_ID'];

  // Get token
  token = await getToken(
          databases: databases, process: 'runScript 1', context: context) ??
      "";
  if (token.isEmpty) {
    context.log('runScript - token is empty, forceRenew');
    token = await getToken(
          databases: databases,
          forceRenew: true,
          process: 'runScript 2',
          context: context,
        ) ??
        "";
  }
  if (token.isEmpty) {
    context.log('runScript - token is STILL empty, return Exception');
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
      return status != null && status < 500;
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
    context.log(
        'runScript - errorInterceptor -  ${error.response} -  ${error.message}');
    return handler.next(error);
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
        context.log(
            'runScript - Token $token is not valid ${response.data}, force a new token request');
        token = await getToken(
              databases: databases,
              forceRenew: true,
              process: 'runScript 3',
              context: context,
            ) ??
            "";
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
          context.log(
              'runScript - Token $token is not valid ${response.data}, force a new token request');
          token = await getToken(
                databases: databases,
                forceRenew: true,
                process: 'runScript 4',
                context: context,
              ) ??
              "";
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
  required appwrite.Databases databases,
  required String layoutName,
  required String recordId,
  required dynamic envVars,
  required context,
}) async {
  filemakerAccountName = envVars['FILEMAKER_ACCOUNT_NAME'];
  filemakerPassword = envVars['FILEMAKER_PASSWORD'];
  filemakerFilename = envVars['FILEMAKER_FILENAME'];
  filemakerDataApiUrl = envVars['FILEMAKER_DATA_API_URL'];
  variablesCollectionId = envVars['VARIABLES_COLLECTION_ID'];
  targetProjectId = envVars['TARGET_PROJECT_ID'];
  databaseId = envVars['DATABASE_ID'];

  // Get token
  token = await getToken(
        databases: databases,
        process: 'getRecordWithRecordId 1',
        context: context,
      ) ??
      "";
  if (token.isEmpty) {
    context.log('getRecordWithRecordId - token is empty, forceRenew');
    token = await getToken(
          databases: databases,
          forceRenew: true,
          process: 'getRecordWithRecordId 2',
          context: context,
        ) ??
        "";
  }
  if (token.isEmpty) {
    context
        .log('getRecordWithRecordId - token is STILL empty, return Exception');
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
      return status != null && status < 500;
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
    return handler.next(error);
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
      context.log(
          'getRecordWithRecordId - Token $token is not valid ${response.data}, force a new token request');
      token = await getToken(
            databases: databases,
            forceRenew: true,
            process: 'getRecordWithRecordId 3',
            context: context,
          ) ??
          "";
      if (token.isEmpty) {
        context.log(
            'getRecordWithRecordId - token is STILL empty, return Exception');
        return Exception('Unable to get a new token');
      }
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
  required appwrite.Databases databases,
  required Map<String, String> globalFields,
  required dynamic envVars,
  required context,
}) async {
  filemakerAccountName = envVars['FILEMAKER_ACCOUNT_NAME'];
  filemakerPassword = envVars['FILEMAKER_PASSWORD'];
  filemakerFilename = envVars['FILEMAKER_FILENAME'];
  filemakerDataApiUrl = envVars['FILEMAKER_DATA_API_URL'];
  variablesCollectionId = envVars['VARIABLES_COLLECTION_ID'];
  targetProjectId = envVars['TARGET_PROJECT_ID'];
  databaseId = envVars['DATABASE_ID'];

  // Get token
  token = await getToken(
        databases: databases,
        process: 'setGlobals 1',
        context: context,
      ) ??
      "";
  if (token.isEmpty) {
    context.log('setGlobals - token is empty, forceRenew');
    token = await getToken(
          databases: databases,
          forceRenew: true,
          process: 'setGlobals 2',
          context: context,
        ) ??
        "";
  }
  if (token.isEmpty) {
    context.log('setGlobals - token is STILL empty, return Exception');
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
      return status != null && status < 500;
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
    context.log(
        'setGlobals - errorInterceptor -  ${error.response} -  ${error.message}');
    return handler.next(error);
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
    context.log('setting globals: $data');
    response = await dio.patch(
      "/databases/$filemakerFilename/globals",
      data: data,
    );
    context.log('setting globals response: ${response.data}');
    var code = response.data['messages'][0]['code'];
    if (code == "952") {
      // Token is not valid, force a new token request
      context.log(
          'setGlobals - Token $token is not valid ${response.data}, force a new token request');
      token = await getToken(
            databases: databases,
            forceRenew: true,
            process: 'setGlobals 3',
            context: context,
          ) ??
          "";
      if (token.isEmpty) {
        context.log('setGlobals - token is STILL empty, return Exception');
        return Exception('Unable to get a new token');
      }
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
