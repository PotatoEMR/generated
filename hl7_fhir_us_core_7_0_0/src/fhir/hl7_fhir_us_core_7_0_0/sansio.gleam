////[https://hl7.org/fhir/hl7_fhir_us_core_7_0_0](https://hl7.org/fhir/hl7_fhir_us_core_7_0_0) hl7_fhir_us_core_7_0_0 sans-io request/response helpers suitable for building clients on top of, such as fhirclient_httpc.gleam and fhirclient_rsvp.gleam

import fhir/hl7_fhir_us_core_7_0_0/resources
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request, Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// FHIR client for sending http requests to server such as
/// `let pat = resources.patient_read("123", client)`
///
/// create client from server base url with fhirclient_new(baseurl)`
///
/// `let assert Ok(client) = sansio.fhirclient_new("hl7_fhir_us_core_7_0_0.smarthealthit.org/")`
///
/// `let assert Ok(client) = sansio.fhirclient_new("https://hl7_fhir_us_core_7_0_0.smarthealthit.org/")`
///
/// `let assert Ok(client) = sansio.fhirclient_new("https://hapi.fhir.org/basehl7_fhir_us_core_7_0_0")`
///
/// `let assert Ok(client) = sansio.fhirclient_new("127.0.0.1:8000")`
pub type FhirClient {
  FhirClient(
    baseurl: uri.Uri,
    basereq: Request(Option(Json)),
    print_sent_requests: Logging,
    print_received_responses: Logging,
  )
}

/// creates a new client from server base url
///
/// `let assert Ok(client) = sansio.fhirclient_new("hl7_fhir_us_core_7_0_0.smarthealthit.org/")`
///
/// `let assert Ok(client) = sansio.fhirclient_new("https://hl7_fhir_us_core_7_0_0.smarthealthit.org/")`
///
/// `let assert Ok(client) = sansio.fhirclient_new("https://hapi.fhir.org/basehl7_fhir_us_core_7_0_0")`
///
/// `let assert Ok(client) = sansio.fhirclient_new("127.0.0.1:8000")`
pub fn fhirclient_new(
  server_base_url in_url: String,
) -> Result(FhirClient, ErrBaseUrl) {
  let in_url = case
    string.starts_with(in_url, "localhost")
    || string.starts_with(in_url, "127.0.0.1")
  {
    False -> in_url
    True -> "http://" <> in_url
  }
  let in_url = case string.starts_with(in_url, "http") {
    True -> in_url
    False -> "https://" <> in_url
  }
  case uri.parse(in_url) {
    Error(_) -> Error(UriParseFail)
    Ok(baseurl) ->
      case baseurl.host {
        None -> Error(UriNoHost)
        Some(host) -> {
          case baseurl.scheme {
            Some("http") -> Ok(create_base_req(http.Http, host, baseurl))
            Some("https") -> Ok(create_base_req(http.Https, host, baseurl))
            _ -> Error(UriNoHttpOrHttps)
          }
        }
      }
  }
}

/// use SMART app access token when making requests with client
pub fn set_access_token(client: FhirClient, token: String) -> FhirClient {
  FhirClient(
    ..client,
    basereq: client.basereq
      |> request.set_header("authorization", "Bearer " <> token),
  )
}

/// a problem with your baseurl in `fhirclient_new(baseurl)`,
/// which you should only see if you have typo in server base url
pub type ErrBaseUrl {
  UriParseFail
  UriNoHttpOrHttps
  UriNoHost
}

pub type Logging {
  LoggingOn
  LoggingOff
}

fn create_base_req(
  scheme: http.Scheme,
  host: String,
  baseurl: uri.Uri,
) -> FhirClient {
  let basereq =
    Request(
      method: http.Get,
      headers: [#("Accept", "application/fhir+json")],
      body: None,
      scheme:,
      host:,
      port: baseurl.port,
      path: case string.ends_with(baseurl.path, "/") {
        True -> string.drop_end(baseurl.path, 1)
        False -> baseurl.path
      },
      query: None,
    )
  FhirClient(
    baseurl:,
    basereq:,
    print_sent_requests: LoggingOff,
    print_received_responses: LoggingOff,
  )
}

pub type ErrResp {
  ///got json but could not parse it, probably a missing required field
  ErrParseJson(json.DecodeError)
  ///did not get resource json, often server eg nginx gives basic html response or empty body with http headers/status code
  ErrServer(Response(String))
  ///got operationoutcome error from fhir server
  ErrOperationoutcome(resources.Operationoutcome)
}

/// convert error response to string,
/// either from a server error response
/// or problem parsing server's returned resource
pub fn err_resp_to_string(err: ErrResp) -> String {
  case err {
    ErrServer(err) -> "server error: " <> resp_to_string(err)
    ErrOperationoutcome(err) ->
      case err.issue.rest {
        [] ->
          "OperationOutcome: "
          <> err.issue.first
          |> resources.operationoutcome_issue_to_json
          |> json.to_string
        _ ->
          "OperationOutcome issues: "
          <> [err.issue.first, ..err.issue.rest]
          |> list.map(resources.operationoutcome_issue_to_json)
          |> json.preprocessed_array
          |> json.to_string
      }
    ErrParseJson(err) ->
      "Error parsing returned resource: "
      <> case err {
        json.UnexpectedEndOfInput -> "unexpected end of input"
        json.UnexpectedByte(err) -> "unexpected byte: " <> err
        json.UnexpectedSequence(err) -> "unexpected sequence: " <> err
        json.UnableToDecode(errors) ->
          list.map(errors, fn(error) {
            let decode.DecodeError(expected:, found:, path:) = error
            "expected "
            <> expected
            <> " but found "
            <> found
            <> " at "
            <> string.join(path, "/")
          })
          |> string.join(";")
      }
  }
}

pub type ErrReq {
  ///could not make an update request because resource has no id
  ErrNoId
}

pub const err_req_to_string = "the resource you're using has no id, but a resource id is needed for this operation"

pub fn any_create_req(
  resource_json: Json,
  res_type: resources.ResourceType,
  client: FhirClient,
) -> Request(Option(Json)) {
  client.basereq
  |> request.set_path(
    string.concat([
      client.basereq.path,
      "/",
      resources.resource_type_to_string(res_type),
    ]),
  )
  |> request.set_header("Content-Type", "application/fhir+json")
  |> request.set_header("Prefer", "return=representation")
  |> request.set_body(Some(resource_json))
  |> request.set_method(http.Post)
}

pub fn any_read_req(
  id: String,
  res_type: resources.ResourceType,
  client: FhirClient,
) -> Request(Option(Json)) {
  client.basereq
  |> request.set_path(
    string.concat([
      client.basereq.path,
      "/",
      resources.resource_type_to_string(res_type),
      "/",
      id,
    ]),
  )
}

pub fn any_update_req(
  id: Option(String),
  resource_json: Json,
  res_type: resources.ResourceType,
  client: FhirClient,
) -> Result(Request(Option(Json)), ErrReq) {
  case id {
    None -> Error(ErrNoId)
    Some(id) ->
      Ok(
        client.basereq
        |> request.set_path(
          string.concat([
            client.basereq.path,
            "/",
            resources.resource_type_to_string(res_type),
            "/",
            id,
          ]),
        )
        |> request.set_header("Content-Type", "application/fhir+json")
        |> request.set_header("Prefer", "return=representation")
        |> request.set_body(Some(resource_json))
        |> request.set_method(http.Put),
      )
  }
}

pub fn any_delete_req(
  id: String,
  res_type: resources.ResourceType,
  client: FhirClient,
) -> Request(Option(Json)) {
  client.basereq
  |> request.set_path(
    string.concat([
      client.basereq.path,
      "/",
      resources.resource_type_to_string(res_type),
      "/",
      id,
    ]),
  )
  |> request.set_method(http.Delete)
}

pub fn any_search_req(
  search_string: String,
  res_type: resources.ResourceType,
  client: FhirClient,
) -> Request(Option(Json)) {
  client.basereq
  |> request.set_path(
    string.concat([
      client.basereq.path,
      "/",
      resources.resource_type_to_string(res_type),
      "?",
      search_string,
    ]),
  )
}

pub fn any_operation_req(
  res_type: resources.ResourceType,
  res_id: Option(String),
  operation_name: String,
  params: Option(resources.Parameters),
  client: FhirClient,
) -> Request(Option(Json)) {
  let path = case res_id {
    Some(res_id) ->
      string.concat([
        client.basereq.path,
        "/",
        resources.resource_type_to_string(res_type),
        "/",
        res_id,
        "/$",
        operation_name,
      ])
    None ->
      string.concat([
        client.basereq.path,
        "/",
        resources.resource_type_to_string(res_type),
        "/$",
        operation_name,
      ])
  }
  let req =
    client.basereq
    |> request.set_path(path)
    |> request.set_header("Content-Type", "application/fhir+json")
    |> request.set_header("Prefer", "return=representation")
  case params {
    None -> req
    Some(params) ->
      req
      |> request.set_body(params |> resources.parameters_to_json |> Some)
      |> request.set_method(http.Post)
  }
}

/// decodes an Ok(resource) of given decoder type
/// or an Error:
/// - decoder error attempting to decode resource
/// - Operationoutcome error
/// - non json http response
pub fn any_response(
  resp: Response(String),
  resource_decoder: decode.Decoder(resource_type),
) -> Result(resource_type, ErrResp) {
  case resp.status < 300 {
    True ->
      resp.body
      |> json.parse(resource_decoder)
      |> result.map_error(ErrParseJson)
    False ->
      Error(case resp.body |> json.parse(resources.operationoutcome_decoder()) {
        Ok(decoded_oo) -> ErrOperationoutcome(decoded_oo)
        Error(_) -> ErrServer(resp)
      })
    // here if operationoutcome fails to decode, we discard the error
    // and instead return response with body as string
    // technically, body might have been a malformed operationoutcome
    // which we could maybe check for with Content-Type header
    // and if it's application/fhir+json then keep operationdecoder outcome
    // that seems fiddly though whereas this is pretty clean
    // and I mean if you have a literal malformed operationoutcome error idk
    // it's an error on an error what are you even going to do with that
  }
}

//
pub fn delete_response(
  resp: Response(String),
) -> Result(OperationoutcomeOrHTTP, ErrResp) {
  case resp.status < 300 {
    True ->
      Ok(case resp.body |> json.parse(resources.operationoutcome_decoder()) {
        Ok(decoded_oo) -> SuccessOperationoutcome(decoded_oo)
        Error(_) -> SuccessHttpResponse(response.Response(..resp, body: Nil))
      })
    False ->
      Error(case resp.body |> json.parse(resources.operationoutcome_decoder()) {
        Ok(decoded_oo) -> ErrOperationoutcome(decoded_oo)
        Error(_) -> ErrServer(resp)
      })
  }
}

pub type OperationoutcomeOrHTTP {
  SuccessOperationoutcome(resources.Operationoutcome)
  SuccessHttpResponse(Response(Nil))
}

pub type PostBundleType {
  /// server executes all operations in transaction as one atomic operation
  Transaction
  /// server executes each operation in batch independently
  /// meaning an operation can fail without stopping other operations
  Batch
}

pub fn batch_req(
  reqs: List(Request(Option(Json))),
  bundle_type: PostBundleType,
  client: FhirClient,
) -> Request(Option(Json)) {
  // each request in list already has serialized json body
  // so we have to construct bundle json as json
  // rather than type safe bundle Bundle variable then serialize
  let base_len = string.length(client.basereq.path) + 1
  // request path is minus server base part
  // eg http://hapi.fhir.org/baseR4/Immunization/123 -> Immunization/123
  let entries =
    reqs
    |> list.map(fn(req) {
      let entry_req =
        json.object([
          #(
            "method",
            case req.method {
              http.Get -> "GET"
              http.Post -> "POST"
              http.Put -> "PUT"
              http.Delete -> "DELETE"
              http.Patch -> "PATCH"
              _ ->
                "invalid http verb which should never happen, you probably called batch_req with reqs created or modified by something other than this module"
            }
              |> json.string,
          ),
          #("url", json.string(string.drop_start(req.path, base_len))),
        ])
      let obj = [#("request", entry_req)]
      let obj = case req.body {
        None -> obj
        Some(resource) -> [#("resource", resource), ..obj]
      }
      json.object(obj)
    })
  let bundle_type = case bundle_type {
    Transaction -> "transaction"
    Batch -> "batch"
  }
  let batch_bundle =
    json.object([
      #("resourceType", json.string("Bundle")),
      #("type", json.string(bundle_type)),
      #("entry", json.preprocessed_array(entries)),
    ])
  client.basereq
  |> request.set_header("Prefer", "return=representation")
  |> request.set_header("Content-Type", "application/fhir+json")
  |> request.set_body(Some(batch_bundle))
  |> request.set_method(http.Post)
}

pub fn bundle_next_page_req(
  bundle: resources.Bundle,
  client: FhirClient,
) -> Result(Request(Option(Json)), Nil) {
  result.try(list.find(bundle.link, fn(l) { l.relation == "next" }), fn(link) {
    result.try(uri.parse(link.url), fn(uri) {
      Ok(Request(..client.basereq, path: uri.path, query: uri.query))
    })
  })
}

pub fn bundle_next_page_req_forgiving(
  bundle: resources.BundleForgiving,
  client: FhirClient,
) -> Result(Request(Option(Json)), Nil) {
  result.try(list.find(bundle.link, fn(l) { l.relation == "next" }), fn(link) {
    result.try(uri.parse(link.url), fn(uri) {
      Ok(Request(..client.basereq, path: uri.path, query: uri.query))
    })
  })
}

pub fn req_to_string(req: Request(Option(Json))) -> String {
  let to_uri = req |> request.to_uri |> uri.to_string
  let method = req.method |> http.method_to_string
  let headers =
    req.headers
    |> list.map(fn(hdr) { hdr.0 <> ": " <> hdr.1 })
    |> string.join("; ")

  //kind of duplicating but want to put body at end and maybe this performs better? idk maybe doesn't matter
  case req.body {
    Some(body) -> [
      "to uri:  " <> to_uri,
      "method:  " <> method,
      "headers: " <> headers,
      "body:    " <> json.to_string(body),
    ]
    None -> [
      "to uri:  " <> to_uri,
      "method:  " <> method,
      "headers: " <> headers,
    ]
  }
  |> string.join("\n")
}

pub fn resp_to_string(resp: Response(String)) -> String {
  let status = resp.status |> int.to_string
  let headers =
    resp.headers
    |> list.map(fn(hdr) { hdr.0 <> ": " <> hdr.1 })
    |> string.join("; ")
  [
    "status:  " <> status,
    "headers: " <> headers,
    "body:    " <> resp.body,
  ]
  |> string.join("\n")
}

pub type GroupedResources {
  GroupedResources(
    bundle: List(resources.Bundle),
    endpoint: List(resources.Endpoint),
    operationoutcome: List(resources.Operationoutcome),
    head_occipital_frontal_circumference_percentile: List(
      resources.HeadOccipitalFrontalCircumferencePercentile,
    ),
    pediatric_bmi_for_age: List(resources.PediatricBmiForAge),
    pediatric_weight_for_height: List(resources.PediatricWeightForHeight),
    us_core_allergyintolerance: List(resources.UsCoreAllergyintolerance),
    us_core_average_blood_pressure: List(resources.UsCoreAverageBloodPressure),
    us_core_blood_pressure: List(resources.UsCoreBloodPressure),
    us_core_bmi: List(resources.UsCoreBmi),
    us_core_body_height: List(resources.UsCoreBodyHeight),
    us_core_body_temperature: List(resources.UsCoreBodyTemperature),
    us_core_body_weight: List(resources.UsCoreBodyWeight),
    us_core_care_experience_preference: List(
      resources.UsCoreCareExperiencePreference,
    ),
    us_core_careplan: List(resources.UsCoreCareplan),
    us_core_careteam: List(resources.UsCoreCareteam),
    us_core_condition_encounter_diagnosis: List(
      resources.UsCoreConditionEncounterDiagnosis,
    ),
    us_core_condition_problems_health_concerns: List(
      resources.UsCoreConditionProblemsHealthConcerns,
    ),
    us_core_coverage: List(resources.UsCoreCoverage),
    us_core_diagnosticreport_lab: List(resources.UsCoreDiagnosticreportLab),
    us_core_diagnosticreport_note: List(resources.UsCoreDiagnosticreportNote),
    us_core_documentreference: List(resources.UsCoreDocumentreference),
    us_core_encounter: List(resources.UsCoreEncounter),
    us_core_goal: List(resources.UsCoreGoal),
    us_core_head_circumference: List(resources.UsCoreHeadCircumference),
    us_core_heart_rate: List(resources.UsCoreHeartRate),
    us_core_immunization: List(resources.UsCoreImmunization),
    us_core_implantable_device: List(resources.UsCoreImplantableDevice),
    us_core_location: List(resources.UsCoreLocation),
    us_core_medication: List(resources.UsCoreMedication),
    us_core_medicationdispense: List(resources.UsCoreMedicationdispense),
    us_core_medicationrequest: List(resources.UsCoreMedicationrequest),
    us_core_observation_clinical_result: List(
      resources.UsCoreObservationClinicalResult,
    ),
    us_core_observation_lab: List(resources.UsCoreObservationLab),
    us_core_observation_occupation: List(resources.UsCoreObservationOccupation),
    us_core_observation_pregnancyintent: List(
      resources.UsCoreObservationPregnancyintent,
    ),
    us_core_observation_pregnancystatus: List(
      resources.UsCoreObservationPregnancystatus,
    ),
    us_core_observation_screening_assessment: List(
      resources.UsCoreObservationScreeningAssessment,
    ),
    us_core_observation_sexual_orientation: List(
      resources.UsCoreObservationSexualOrientation,
    ),
    us_core_organization: List(resources.UsCoreOrganization),
    us_core_patient: List(resources.UsCorePatient),
    us_core_practitioner: List(resources.UsCorePractitioner),
    us_core_practitionerrole: List(resources.UsCorePractitionerrole),
    us_core_procedure: List(resources.UsCoreProcedure),
    us_core_provenance: List(resources.UsCoreProvenance),
    us_core_pulse_oximetry: List(resources.UsCorePulseOximetry),
    us_core_questionnaireresponse: List(resources.UsCoreQuestionnaireresponse),
    us_core_relatedperson: List(resources.UsCoreRelatedperson),
    us_core_respiratory_rate: List(resources.UsCoreRespiratoryRate),
    us_core_servicerequest: List(resources.UsCoreServicerequest),
    us_core_simple_observation: List(resources.UsCoreSimpleObservation),
    us_core_smokingstatus: List(resources.UsCoreSmokingstatus),
    us_core_specimen: List(resources.UsCoreSpecimen),
    us_core_treatment_intervention_preference: List(
      resources.UsCoreTreatmentInterventionPreference,
    ),
    us_core_vital_signs: List(resources.UsCoreVitalSigns),
  )
}

pub fn groupedresources_new() -> GroupedResources {
  GroupedResources(
    bundle: [],
    endpoint: [],
    operationoutcome: [],
    head_occipital_frontal_circumference_percentile: [],
    pediatric_bmi_for_age: [],
    pediatric_weight_for_height: [],
    us_core_allergyintolerance: [],
    us_core_average_blood_pressure: [],
    us_core_blood_pressure: [],
    us_core_bmi: [],
    us_core_body_height: [],
    us_core_body_temperature: [],
    us_core_body_weight: [],
    us_core_care_experience_preference: [],
    us_core_careplan: [],
    us_core_careteam: [],
    us_core_condition_encounter_diagnosis: [],
    us_core_condition_problems_health_concerns: [],
    us_core_coverage: [],
    us_core_diagnosticreport_lab: [],
    us_core_diagnosticreport_note: [],
    us_core_documentreference: [],
    us_core_encounter: [],
    us_core_goal: [],
    us_core_head_circumference: [],
    us_core_heart_rate: [],
    us_core_immunization: [],
    us_core_implantable_device: [],
    us_core_location: [],
    us_core_medication: [],
    us_core_medicationdispense: [],
    us_core_medicationrequest: [],
    us_core_observation_clinical_result: [],
    us_core_observation_lab: [],
    us_core_observation_occupation: [],
    us_core_observation_pregnancyintent: [],
    us_core_observation_pregnancystatus: [],
    us_core_observation_screening_assessment: [],
    us_core_observation_sexual_orientation: [],
    us_core_organization: [],
    us_core_patient: [],
    us_core_practitioner: [],
    us_core_practitionerrole: [],
    us_core_procedure: [],
    us_core_provenance: [],
    us_core_pulse_oximetry: [],
    us_core_questionnaireresponse: [],
    us_core_relatedperson: [],
    us_core_respiratory_rate: [],
    us_core_servicerequest: [],
    us_core_simple_observation: [],
    us_core_smokingstatus: [],
    us_core_specimen: [],
    us_core_treatment_intervention_preference: [],
    us_core_vital_signs: [],
  )
}

pub fn bundle_to_groupedresources(
  from bundle: resources.Bundle,
) -> GroupedResources {
  list.fold(
    from: groupedresources_new(),
    over: bundle.entry,
    with: fn(acc, entry) {
      case entry.resource {
        None -> acc
        Some(res) ->
          case res {
            resources.ResourceBundle(r) ->
              GroupedResources(..acc, bundle: [r, ..acc.bundle])
            resources.ResourceEndpoint(r) ->
              GroupedResources(..acc, endpoint: [r, ..acc.endpoint])
            resources.ResourceOperationoutcome(r) ->
              GroupedResources(..acc, operationoutcome: [
                r,
                ..acc.operationoutcome
              ])
            resources.ResourceHeadOccipitalFrontalCircumferencePercentile(r) ->
              GroupedResources(
                ..acc,
                head_occipital_frontal_circumference_percentile: [
                  r,
                  ..acc.head_occipital_frontal_circumference_percentile
                ],
              )
            resources.ResourcePediatricBmiForAge(r) ->
              GroupedResources(..acc, pediatric_bmi_for_age: [
                r,
                ..acc.pediatric_bmi_for_age
              ])
            resources.ResourcePediatricWeightForHeight(r) ->
              GroupedResources(..acc, pediatric_weight_for_height: [
                r,
                ..acc.pediatric_weight_for_height
              ])
            resources.ResourceUsCoreAllergyintolerance(r) ->
              GroupedResources(..acc, us_core_allergyintolerance: [
                r,
                ..acc.us_core_allergyintolerance
              ])
            resources.ResourceUsCoreAverageBloodPressure(r) ->
              GroupedResources(..acc, us_core_average_blood_pressure: [
                r,
                ..acc.us_core_average_blood_pressure
              ])
            resources.ResourceUsCoreBloodPressure(r) ->
              GroupedResources(..acc, us_core_blood_pressure: [
                r,
                ..acc.us_core_blood_pressure
              ])
            resources.ResourceUsCoreBmi(r) ->
              GroupedResources(..acc, us_core_bmi: [r, ..acc.us_core_bmi])
            resources.ResourceUsCoreBodyHeight(r) ->
              GroupedResources(..acc, us_core_body_height: [
                r,
                ..acc.us_core_body_height
              ])
            resources.ResourceUsCoreBodyTemperature(r) ->
              GroupedResources(..acc, us_core_body_temperature: [
                r,
                ..acc.us_core_body_temperature
              ])
            resources.ResourceUsCoreBodyWeight(r) ->
              GroupedResources(..acc, us_core_body_weight: [
                r,
                ..acc.us_core_body_weight
              ])
            resources.ResourceUsCoreCareExperiencePreference(r) ->
              GroupedResources(..acc, us_core_care_experience_preference: [
                r,
                ..acc.us_core_care_experience_preference
              ])
            resources.ResourceUsCoreCareplan(r) ->
              GroupedResources(..acc, us_core_careplan: [
                r,
                ..acc.us_core_careplan
              ])
            resources.ResourceUsCoreCareteam(r) ->
              GroupedResources(..acc, us_core_careteam: [
                r,
                ..acc.us_core_careteam
              ])
            resources.ResourceUsCoreConditionEncounterDiagnosis(r) ->
              GroupedResources(..acc, us_core_condition_encounter_diagnosis: [
                r,
                ..acc.us_core_condition_encounter_diagnosis
              ])
            resources.ResourceUsCoreConditionProblemsHealthConcerns(r) ->
              GroupedResources(
                ..acc,
                us_core_condition_problems_health_concerns: [
                  r,
                  ..acc.us_core_condition_problems_health_concerns
                ],
              )
            resources.ResourceUsCoreCoverage(r) ->
              GroupedResources(..acc, us_core_coverage: [
                r,
                ..acc.us_core_coverage
              ])
            resources.ResourceUsCoreDiagnosticreportLab(r) ->
              GroupedResources(..acc, us_core_diagnosticreport_lab: [
                r,
                ..acc.us_core_diagnosticreport_lab
              ])
            resources.ResourceUsCoreDiagnosticreportNote(r) ->
              GroupedResources(..acc, us_core_diagnosticreport_note: [
                r,
                ..acc.us_core_diagnosticreport_note
              ])
            resources.ResourceUsCoreDocumentreference(r) ->
              GroupedResources(..acc, us_core_documentreference: [
                r,
                ..acc.us_core_documentreference
              ])
            resources.ResourceUsCoreEncounter(r) ->
              GroupedResources(..acc, us_core_encounter: [
                r,
                ..acc.us_core_encounter
              ])
            resources.ResourceUsCoreGoal(r) ->
              GroupedResources(..acc, us_core_goal: [r, ..acc.us_core_goal])
            resources.ResourceUsCoreHeadCircumference(r) ->
              GroupedResources(..acc, us_core_head_circumference: [
                r,
                ..acc.us_core_head_circumference
              ])
            resources.ResourceUsCoreHeartRate(r) ->
              GroupedResources(..acc, us_core_heart_rate: [
                r,
                ..acc.us_core_heart_rate
              ])
            resources.ResourceUsCoreImmunization(r) ->
              GroupedResources(..acc, us_core_immunization: [
                r,
                ..acc.us_core_immunization
              ])
            resources.ResourceUsCoreImplantableDevice(r) ->
              GroupedResources(..acc, us_core_implantable_device: [
                r,
                ..acc.us_core_implantable_device
              ])
            resources.ResourceUsCoreLocation(r) ->
              GroupedResources(..acc, us_core_location: [
                r,
                ..acc.us_core_location
              ])
            resources.ResourceUsCoreMedication(r) ->
              GroupedResources(..acc, us_core_medication: [
                r,
                ..acc.us_core_medication
              ])
            resources.ResourceUsCoreMedicationdispense(r) ->
              GroupedResources(..acc, us_core_medicationdispense: [
                r,
                ..acc.us_core_medicationdispense
              ])
            resources.ResourceUsCoreMedicationrequest(r) ->
              GroupedResources(..acc, us_core_medicationrequest: [
                r,
                ..acc.us_core_medicationrequest
              ])
            resources.ResourceUsCoreObservationClinicalResult(r) ->
              GroupedResources(..acc, us_core_observation_clinical_result: [
                r,
                ..acc.us_core_observation_clinical_result
              ])
            resources.ResourceUsCoreObservationLab(r) ->
              GroupedResources(..acc, us_core_observation_lab: [
                r,
                ..acc.us_core_observation_lab
              ])
            resources.ResourceUsCoreObservationOccupation(r) ->
              GroupedResources(..acc, us_core_observation_occupation: [
                r,
                ..acc.us_core_observation_occupation
              ])
            resources.ResourceUsCoreObservationPregnancyintent(r) ->
              GroupedResources(..acc, us_core_observation_pregnancyintent: [
                r,
                ..acc.us_core_observation_pregnancyintent
              ])
            resources.ResourceUsCoreObservationPregnancystatus(r) ->
              GroupedResources(..acc, us_core_observation_pregnancystatus: [
                r,
                ..acc.us_core_observation_pregnancystatus
              ])
            resources.ResourceUsCoreObservationScreeningAssessment(r) ->
              GroupedResources(..acc, us_core_observation_screening_assessment: [
                r,
                ..acc.us_core_observation_screening_assessment
              ])
            resources.ResourceUsCoreObservationSexualOrientation(r) ->
              GroupedResources(..acc, us_core_observation_sexual_orientation: [
                r,
                ..acc.us_core_observation_sexual_orientation
              ])
            resources.ResourceUsCoreOrganization(r) ->
              GroupedResources(..acc, us_core_organization: [
                r,
                ..acc.us_core_organization
              ])
            resources.ResourceUsCorePatient(r) ->
              GroupedResources(..acc, us_core_patient: [
                r,
                ..acc.us_core_patient
              ])
            resources.ResourceUsCorePractitioner(r) ->
              GroupedResources(..acc, us_core_practitioner: [
                r,
                ..acc.us_core_practitioner
              ])
            resources.ResourceUsCorePractitionerrole(r) ->
              GroupedResources(..acc, us_core_practitionerrole: [
                r,
                ..acc.us_core_practitionerrole
              ])
            resources.ResourceUsCoreProcedure(r) ->
              GroupedResources(..acc, us_core_procedure: [
                r,
                ..acc.us_core_procedure
              ])
            resources.ResourceUsCoreProvenance(r) ->
              GroupedResources(..acc, us_core_provenance: [
                r,
                ..acc.us_core_provenance
              ])
            resources.ResourceUsCorePulseOximetry(r) ->
              GroupedResources(..acc, us_core_pulse_oximetry: [
                r,
                ..acc.us_core_pulse_oximetry
              ])
            resources.ResourceUsCoreQuestionnaireresponse(r) ->
              GroupedResources(..acc, us_core_questionnaireresponse: [
                r,
                ..acc.us_core_questionnaireresponse
              ])
            resources.ResourceUsCoreRelatedperson(r) ->
              GroupedResources(..acc, us_core_relatedperson: [
                r,
                ..acc.us_core_relatedperson
              ])
            resources.ResourceUsCoreRespiratoryRate(r) ->
              GroupedResources(..acc, us_core_respiratory_rate: [
                r,
                ..acc.us_core_respiratory_rate
              ])
            resources.ResourceUsCoreServicerequest(r) ->
              GroupedResources(..acc, us_core_servicerequest: [
                r,
                ..acc.us_core_servicerequest
              ])
            resources.ResourceUsCoreSimpleObservation(r) ->
              GroupedResources(..acc, us_core_simple_observation: [
                r,
                ..acc.us_core_simple_observation
              ])
            resources.ResourceUsCoreSmokingstatus(r) ->
              GroupedResources(..acc, us_core_smokingstatus: [
                r,
                ..acc.us_core_smokingstatus
              ])
            resources.ResourceUsCoreSpecimen(r) ->
              GroupedResources(..acc, us_core_specimen: [
                r,
                ..acc.us_core_specimen
              ])
            resources.ResourceUsCoreTreatmentInterventionPreference(r) ->
              GroupedResources(
                ..acc,
                us_core_treatment_intervention_preference: [
                  r,
                  ..acc.us_core_treatment_intervention_preference
                ],
              )
            resources.ResourceUsCoreVitalSigns(r) ->
              GroupedResources(..acc, us_core_vital_signs: [
                r,
                ..acc.us_core_vital_signs
              ])
            _ -> acc
          }
      }
    },
  )
}
