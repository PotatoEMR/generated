////[https://hl7.org/fhir/hl7_fhir_us_core_7_0_0](https://hl7.org/fhir/hl7_fhir_us_core_7_0_0) hl7_fhir_us_core_7_0_0 client using httpc

import fhir/hl7_fhir_us_core_7_0_0/resources
import fhir/hl7_fhir_us_core_7_0_0/sansio.{type FhirClient}
import fhir/hl7_fhir_us_core_7_0_0/search_params
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Err {
  ErrHttpc(err: httpc.HttpError)
  ErrSansio(err: ErrFromSansio)
}

pub type ErrFromSansio {
  ///got json but could not parse it, probably a missing required field
  ErrParseJson(json.DecodeError)
  ///did not get resource json, often server eg nginx gives basic html response
  ErrServer(Response(String))
  ///got operationoutcome error from fhir server
  ErrOperationoutcome(resources.Operationoutcome)
  ///could not make an update or delete request because resource has no id
  ErrNoId
}

pub fn err_to_string(err: Err) -> String {
  case err {
    ErrSansio(err:) ->
      case err {
        ErrParseJson(err) -> sansio.err_resp_to_string(sansio.ErrParseJson(err))
        ErrServer(err) -> sansio.err_resp_to_string(sansio.ErrServer(err))
        ErrOperationoutcome(err) ->
          sansio.err_resp_to_string(sansio.ErrOperationoutcome(err))
        ErrNoId -> sansio.err_req_to_string
      }
    ErrHttpc(err:) -> http_err_to_string(err)
  }
}

fn any_create(
  resource: Json,
  res_type: resources.ResourceType,
  resource_dec: Decoder(r),
  client: FhirClient,
) -> Result(r, Err) {
  let req = sansio.any_create_req(resource, res_type, client)
  sendreq_parseresource(req, resource_dec, client)
}

fn any_read(
  id: String,
  client: FhirClient,
  res_type: resources.ResourceType,
  resource_dec: Decoder(a),
) -> Result(a, Err) {
  let req = sansio.any_read_req(id, res_type, client)
  sendreq_parseresource(req, resource_dec, client)
}

fn any_update(
  id: Option(String),
  resource: Json,
  res_type: resources.ResourceType,
  res_dec: Decoder(r),
  client: FhirClient,
) -> Result(r, Err) {
  let req = sansio.any_update_req(id, resource, res_type, client)
  case req {
    Ok(req) -> sendreq_parseresource(req, res_dec, client)
    Error(_) -> Error(ErrSansio(ErrNoId))
    //can have error preparing update request if resource has no id
  }
}

pub fn any_delete(
  id: String,
  res_type: resources.ResourceType,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  let req = sansio.any_delete_req(id, res_type, client)
  case httpc.send(req |> request.set_body("")) {
    Error(err) -> Error(ErrHttpc(err))
    Ok(resp) ->
      case sansio.delete_response(resp) {
        Ok(oo_or_http) -> Ok(oo_or_http)
        Error(err) ->
          Error(
            ErrSansio(case err {
              sansio.ErrParseJson(e) -> ErrParseJson(e)
              sansio.ErrServer(e) -> ErrServer(e)
              sansio.ErrOperationoutcome(e) -> ErrOperationoutcome(e)
            }),
          )
      }
  }
}

/// write out search string manually, in case typed search params don't work
pub fn search_any(
  search_string: String,
  res_type: resources.ResourceType,
  client: FhirClient,
) -> Result(resources.Bundle, Err) {
  sansio.any_search_req(search_string, res_type, client)
  |> sendreq_parseresource(resources.bundle_decoder(), client)
}

/// get all resources in paginated bundle,
/// then stick them all in one bundle and pretend not paginated
///
/// fhirclient_httpc.search_any("name=e&_count=25", "Patient", client) |> fhirclient_httpc.all_pages(client)
pub fn all_pages(
  first_bundle: Result(resources.Bundle, Err),
  client: FhirClient,
) -> Result(resources.Bundle, Err) {
  case all_pages_loop(first_bundle, [], client) {
    Error(err) -> Error(err)
    Ok(#(last_bundle, bundles)) -> {
      let entries =
        list.fold(from: [], over: bundles, with: fn(acc, bundle) {
          list.append(bundle.entry, acc)
        })
      Ok(resources.Bundle(..last_bundle, entry: entries, link: []))
    }
  }
}

/// searchs each bundle and returns list
/// also returns last bundle individually
/// because all_pages smushes everything in there
fn all_pages_loop(
  curr_bundle: Result(resources.Bundle, Err),
  acc_bundles: List(resources.Bundle),
  client: FhirClient,
) -> Result(#(resources.Bundle, List(resources.Bundle)), Err) {
  case curr_bundle {
    Error(err) -> Error(err)
    Ok(curr_bundle) -> {
      let acc_bundles = [curr_bundle, ..acc_bundles]
      case sansio.bundle_next_page_req(curr_bundle, client) {
        // Error(_) -> reached last page
        Error(_) -> Ok(#(curr_bundle, acc_bundles))
        Ok(req) -> {
          let next =
            sendreq_parseresource(req, resources.bundle_decoder(), client)
          all_pages_loop(next, acc_bundles, client)
        }
      }
    }
  }
}

pub fn all_pages_forgiving(
  first_bundle: Result(resources.BundleForgiving, Err),
  client: FhirClient,
) -> Result(resources.BundleForgiving, Err) {
  case all_pages_loop_forgiving(first_bundle, [], client) {
    Error(err) -> Error(err)
    Ok(#(last_bundle, bundles)) -> {
      let entries =
        list.fold(from: [], over: bundles, with: fn(acc, bundle) {
          list.append(bundle.entry, acc)
        })
      Ok(resources.BundleForgiving(..last_bundle, entry: entries, link: []))
    }
  }
}

// arguably very duplicated, maybe should be combined somehow
fn all_pages_loop_forgiving(
  curr_bundle: Result(resources.BundleForgiving, Err),
  acc_bundles: List(resources.BundleForgiving),
  client: FhirClient,
) -> Result(#(resources.BundleForgiving, List(resources.BundleForgiving)), Err) {
  case curr_bundle {
    Error(err) -> Error(err)
    Ok(curr_bundle) -> {
      let acc_bundles = [curr_bundle, ..acc_bundles]
      case sansio.bundle_next_page_req_forgiving(curr_bundle, client) {
        // Error(_) -> reached last page
        Error(_) -> Ok(#(curr_bundle, acc_bundles))
        Ok(req) -> {
          let next =
            sendreq_parseresource(
              req,
              resources.bundle_decoder_forgiving(),
              client,
            )
          all_pages_loop_forgiving(next, acc_bundles, client)
        }
      }
    }
  }
}

/// instead of failing whole decoder on bundle entry with invalid resource,
/// return valid resources alongside list of errors
pub fn search_any_forgiving(
  search_string: String,
  res_type: resources.ResourceType,
  client: FhirClient,
) -> Result(resources.BundleForgiving, Err) {
  sansio.any_search_req(search_string, res_type, client)
  |> sendreq_parseresource(resources.bundle_decoder_forgiving(), client)
}

/// run any operation string on any resource type, optionally using Parameters
pub fn operation_any(
  params params: Option(resources.Parameters),
  operation_name operation_name: String,
  res_type res_type: resources.ResourceType,
  res_id res_id: Option(String),
  res_decoder res_decoder: Decoder(res),
  client client: FhirClient,
) -> Result(res, Err) {
  let req =
    sansio.any_operation_req(res_type, res_id, operation_name, params, client)
  sendreq_parseresource(req, res_decoder, client)
}

pub fn batch(
  reqs: List(Request(Option(Json))),
  bundle_type: sansio.PostBundleType,
  client: FhirClient,
) -> Result(resources.Bundle, Err) {
  let req = sansio.batch_req(reqs, bundle_type, client)
  sendreq_parseresource(req, resources.bundle_decoder(), client)
}

fn sendreq_parseresource(
  req: Request(Option(Json)),
  res_dec: Decoder(r),
  client: sansio.FhirClient,
) -> Result(r, Err) {
  case client.print_sent_requests {
    sansio.LoggingOn -> req |> sansio.req_to_string |> io.println
    sansio.LoggingOff -> Nil
  }
  let req =
    request.set_body(req, case req.body {
      None -> ""
      Some(body) -> json.to_string(body)
    })
  let resp = httpc.send(req)
  case client.print_received_responses {
    sansio.LoggingOn ->
      case resp {
        Ok(resp) -> resp |> sansio.resp_to_string
        Error(err) -> err |> http_err_to_string
      }
      |> io.println
    sansio.LoggingOff -> Nil
  }
  case resp {
    Error(err) -> Error(ErrHttpc(err))
    Ok(resp) ->
      case sansio.any_response(resp, res_dec) {
        Ok(resource) -> Ok(resource)
        Error(err) ->
          Error(
            ErrSansio(case err {
              sansio.ErrParseJson(e) -> ErrParseJson(e)
              sansio.ErrServer(e) -> ErrServer(e)
              sansio.ErrOperationoutcome(e) -> ErrOperationoutcome(e)
            }),
          )
      }
  }
}

fn http_err_to_string(err: httpc.HttpError) {
  case err {
    httpc.InvalidUtf8Response -> "non-UTF-8 data in response"
    httpc.FailedToConnect(ip4:, ip6:) ->
      "could not connect to host: ip4 "
      <> connect_err_to_string(ip4)
      <> ", ip6 "
      <> connect_err_to_string(ip6)
    httpc.ResponseTimeout -> "timed out waiting for response"
  }
}

fn connect_err_to_string(err: httpc.ConnectError) -> String {
  case err {
    httpc.Posix(code:) -> "posix code " <> code
    httpc.TlsAlert(code:, detail:) ->
      "TLS alert code " <> code <> " and detail " <> detail
  }
}

pub fn bundle_create(
  resource: resources.Bundle,
  client: FhirClient,
) -> Result(resources.Bundle, Err) {
  any_create(
    resources.bundle_to_json(resource),
    resources.RtBundle,
    resources.bundle_decoder(),
    client,
  )
}

pub fn bundle_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Bundle, Err) {
  any_read(id, client, resources.RtBundle, resources.bundle_decoder())
}

pub fn bundle_update(
  resource: resources.Bundle,
  client: FhirClient,
) -> Result(resources.Bundle, Err) {
  any_update(
    resource.id,
    resources.bundle_to_json(resource),
    resources.RtBundle,
    resources.bundle_decoder(),
    client,
  )
}

pub fn bundle_delete(
  resource: resources.Bundle,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtBundle, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn endpoint_create(
  resource: resources.Endpoint,
  client: FhirClient,
) -> Result(resources.Endpoint, Err) {
  any_create(
    resources.endpoint_to_json(resource),
    resources.RtEndpoint,
    resources.endpoint_decoder(),
    client,
  )
}

pub fn endpoint_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Endpoint, Err) {
  any_read(id, client, resources.RtEndpoint, resources.endpoint_decoder())
}

pub fn endpoint_update(
  resource: resources.Endpoint,
  client: FhirClient,
) -> Result(resources.Endpoint, Err) {
  any_update(
    resource.id,
    resources.endpoint_to_json(resource),
    resources.RtEndpoint,
    resources.endpoint_decoder(),
    client,
  )
}

pub fn endpoint_delete(
  resource: resources.Endpoint,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtEndpoint, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn operationoutcome_create(
  resource: resources.Operationoutcome,
  client: FhirClient,
) -> Result(resources.Operationoutcome, Err) {
  any_create(
    resources.operationoutcome_to_json(resource),
    resources.RtOperationoutcome,
    resources.operationoutcome_decoder(),
    client,
  )
}

pub fn operationoutcome_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Operationoutcome, Err) {
  any_read(
    id,
    client,
    resources.RtOperationoutcome,
    resources.operationoutcome_decoder(),
  )
}

pub fn operationoutcome_update(
  resource: resources.Operationoutcome,
  client: FhirClient,
) -> Result(resources.Operationoutcome, Err) {
  any_update(
    resource.id,
    resources.operationoutcome_to_json(resource),
    resources.RtOperationoutcome,
    resources.operationoutcome_decoder(),
    client,
  )
}

pub fn operationoutcome_delete(
  resource: resources.Operationoutcome,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtOperationoutcome, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn head_occipital_frontal_circumference_percentile_create(
  resource: resources.HeadOccipitalFrontalCircumferencePercentile,
  client: FhirClient,
) -> Result(resources.HeadOccipitalFrontalCircumferencePercentile, Err) {
  any_create(
    resources.head_occipital_frontal_circumference_percentile_to_json(resource),
    resources.RtObservation,
    resources.head_occipital_frontal_circumference_percentile_decoder(),
    client,
  )
}

pub fn head_occipital_frontal_circumference_percentile_read(
  id: String,
  client: FhirClient,
) -> Result(resources.HeadOccipitalFrontalCircumferencePercentile, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.head_occipital_frontal_circumference_percentile_decoder(),
  )
}

pub fn head_occipital_frontal_circumference_percentile_update(
  resource: resources.HeadOccipitalFrontalCircumferencePercentile,
  client: FhirClient,
) -> Result(resources.HeadOccipitalFrontalCircumferencePercentile, Err) {
  any_update(
    resource.id,
    resources.head_occipital_frontal_circumference_percentile_to_json(resource),
    resources.RtObservation,
    resources.head_occipital_frontal_circumference_percentile_decoder(),
    client,
  )
}

pub fn head_occipital_frontal_circumference_percentile_delete(
  resource: resources.HeadOccipitalFrontalCircumferencePercentile,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn pediatric_bmi_for_age_create(
  resource: resources.PediatricBmiForAge,
  client: FhirClient,
) -> Result(resources.PediatricBmiForAge, Err) {
  any_create(
    resources.pediatric_bmi_for_age_to_json(resource),
    resources.RtObservation,
    resources.pediatric_bmi_for_age_decoder(),
    client,
  )
}

pub fn pediatric_bmi_for_age_read(
  id: String,
  client: FhirClient,
) -> Result(resources.PediatricBmiForAge, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.pediatric_bmi_for_age_decoder(),
  )
}

pub fn pediatric_bmi_for_age_update(
  resource: resources.PediatricBmiForAge,
  client: FhirClient,
) -> Result(resources.PediatricBmiForAge, Err) {
  any_update(
    resource.id,
    resources.pediatric_bmi_for_age_to_json(resource),
    resources.RtObservation,
    resources.pediatric_bmi_for_age_decoder(),
    client,
  )
}

pub fn pediatric_bmi_for_age_delete(
  resource: resources.PediatricBmiForAge,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn pediatric_weight_for_height_create(
  resource: resources.PediatricWeightForHeight,
  client: FhirClient,
) -> Result(resources.PediatricWeightForHeight, Err) {
  any_create(
    resources.pediatric_weight_for_height_to_json(resource),
    resources.RtObservation,
    resources.pediatric_weight_for_height_decoder(),
    client,
  )
}

pub fn pediatric_weight_for_height_read(
  id: String,
  client: FhirClient,
) -> Result(resources.PediatricWeightForHeight, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.pediatric_weight_for_height_decoder(),
  )
}

pub fn pediatric_weight_for_height_update(
  resource: resources.PediatricWeightForHeight,
  client: FhirClient,
) -> Result(resources.PediatricWeightForHeight, Err) {
  any_update(
    resource.id,
    resources.pediatric_weight_for_height_to_json(resource),
    resources.RtObservation,
    resources.pediatric_weight_for_height_decoder(),
    client,
  )
}

pub fn pediatric_weight_for_height_delete(
  resource: resources.PediatricWeightForHeight,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_allergyintolerance_create(
  resource: resources.UsCoreAllergyintolerance,
  client: FhirClient,
) -> Result(resources.UsCoreAllergyintolerance, Err) {
  any_create(
    resources.us_core_allergyintolerance_to_json(resource),
    resources.RtAllergyintolerance,
    resources.us_core_allergyintolerance_decoder(),
    client,
  )
}

pub fn us_core_allergyintolerance_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreAllergyintolerance, Err) {
  any_read(
    id,
    client,
    resources.RtAllergyintolerance,
    resources.us_core_allergyintolerance_decoder(),
  )
}

pub fn us_core_allergyintolerance_update(
  resource: resources.UsCoreAllergyintolerance,
  client: FhirClient,
) -> Result(resources.UsCoreAllergyintolerance, Err) {
  any_update(
    resource.id,
    resources.us_core_allergyintolerance_to_json(resource),
    resources.RtAllergyintolerance,
    resources.us_core_allergyintolerance_decoder(),
    client,
  )
}

pub fn us_core_allergyintolerance_delete(
  resource: resources.UsCoreAllergyintolerance,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtAllergyintolerance, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_average_blood_pressure_create(
  resource: resources.UsCoreAverageBloodPressure,
  client: FhirClient,
) -> Result(resources.UsCoreAverageBloodPressure, Err) {
  any_create(
    resources.us_core_average_blood_pressure_to_json(resource),
    resources.RtObservation,
    resources.us_core_average_blood_pressure_decoder(),
    client,
  )
}

pub fn us_core_average_blood_pressure_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreAverageBloodPressure, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_average_blood_pressure_decoder(),
  )
}

pub fn us_core_average_blood_pressure_update(
  resource: resources.UsCoreAverageBloodPressure,
  client: FhirClient,
) -> Result(resources.UsCoreAverageBloodPressure, Err) {
  any_update(
    resource.id,
    resources.us_core_average_blood_pressure_to_json(resource),
    resources.RtObservation,
    resources.us_core_average_blood_pressure_decoder(),
    client,
  )
}

pub fn us_core_average_blood_pressure_delete(
  resource: resources.UsCoreAverageBloodPressure,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_blood_pressure_create(
  resource: resources.UsCoreBloodPressure,
  client: FhirClient,
) -> Result(resources.UsCoreBloodPressure, Err) {
  any_create(
    resources.us_core_blood_pressure_to_json(resource),
    resources.RtObservation,
    resources.us_core_blood_pressure_decoder(),
    client,
  )
}

pub fn us_core_blood_pressure_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreBloodPressure, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_blood_pressure_decoder(),
  )
}

pub fn us_core_blood_pressure_update(
  resource: resources.UsCoreBloodPressure,
  client: FhirClient,
) -> Result(resources.UsCoreBloodPressure, Err) {
  any_update(
    resource.id,
    resources.us_core_blood_pressure_to_json(resource),
    resources.RtObservation,
    resources.us_core_blood_pressure_decoder(),
    client,
  )
}

pub fn us_core_blood_pressure_delete(
  resource: resources.UsCoreBloodPressure,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_bmi_create(
  resource: resources.UsCoreBmi,
  client: FhirClient,
) -> Result(resources.UsCoreBmi, Err) {
  any_create(
    resources.us_core_bmi_to_json(resource),
    resources.RtObservation,
    resources.us_core_bmi_decoder(),
    client,
  )
}

pub fn us_core_bmi_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreBmi, Err) {
  any_read(id, client, resources.RtObservation, resources.us_core_bmi_decoder())
}

pub fn us_core_bmi_update(
  resource: resources.UsCoreBmi,
  client: FhirClient,
) -> Result(resources.UsCoreBmi, Err) {
  any_update(
    resource.id,
    resources.us_core_bmi_to_json(resource),
    resources.RtObservation,
    resources.us_core_bmi_decoder(),
    client,
  )
}

pub fn us_core_bmi_delete(
  resource: resources.UsCoreBmi,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_body_height_create(
  resource: resources.UsCoreBodyHeight,
  client: FhirClient,
) -> Result(resources.UsCoreBodyHeight, Err) {
  any_create(
    resources.us_core_body_height_to_json(resource),
    resources.RtObservation,
    resources.us_core_body_height_decoder(),
    client,
  )
}

pub fn us_core_body_height_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreBodyHeight, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_body_height_decoder(),
  )
}

pub fn us_core_body_height_update(
  resource: resources.UsCoreBodyHeight,
  client: FhirClient,
) -> Result(resources.UsCoreBodyHeight, Err) {
  any_update(
    resource.id,
    resources.us_core_body_height_to_json(resource),
    resources.RtObservation,
    resources.us_core_body_height_decoder(),
    client,
  )
}

pub fn us_core_body_height_delete(
  resource: resources.UsCoreBodyHeight,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_body_temperature_create(
  resource: resources.UsCoreBodyTemperature,
  client: FhirClient,
) -> Result(resources.UsCoreBodyTemperature, Err) {
  any_create(
    resources.us_core_body_temperature_to_json(resource),
    resources.RtObservation,
    resources.us_core_body_temperature_decoder(),
    client,
  )
}

pub fn us_core_body_temperature_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreBodyTemperature, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_body_temperature_decoder(),
  )
}

pub fn us_core_body_temperature_update(
  resource: resources.UsCoreBodyTemperature,
  client: FhirClient,
) -> Result(resources.UsCoreBodyTemperature, Err) {
  any_update(
    resource.id,
    resources.us_core_body_temperature_to_json(resource),
    resources.RtObservation,
    resources.us_core_body_temperature_decoder(),
    client,
  )
}

pub fn us_core_body_temperature_delete(
  resource: resources.UsCoreBodyTemperature,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_body_weight_create(
  resource: resources.UsCoreBodyWeight,
  client: FhirClient,
) -> Result(resources.UsCoreBodyWeight, Err) {
  any_create(
    resources.us_core_body_weight_to_json(resource),
    resources.RtObservation,
    resources.us_core_body_weight_decoder(),
    client,
  )
}

pub fn us_core_body_weight_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreBodyWeight, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_body_weight_decoder(),
  )
}

pub fn us_core_body_weight_update(
  resource: resources.UsCoreBodyWeight,
  client: FhirClient,
) -> Result(resources.UsCoreBodyWeight, Err) {
  any_update(
    resource.id,
    resources.us_core_body_weight_to_json(resource),
    resources.RtObservation,
    resources.us_core_body_weight_decoder(),
    client,
  )
}

pub fn us_core_body_weight_delete(
  resource: resources.UsCoreBodyWeight,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_care_experience_preference_create(
  resource: resources.UsCoreCareExperiencePreference,
  client: FhirClient,
) -> Result(resources.UsCoreCareExperiencePreference, Err) {
  any_create(
    resources.us_core_care_experience_preference_to_json(resource),
    resources.RtObservation,
    resources.us_core_care_experience_preference_decoder(),
    client,
  )
}

pub fn us_core_care_experience_preference_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreCareExperiencePreference, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_care_experience_preference_decoder(),
  )
}

pub fn us_core_care_experience_preference_update(
  resource: resources.UsCoreCareExperiencePreference,
  client: FhirClient,
) -> Result(resources.UsCoreCareExperiencePreference, Err) {
  any_update(
    resource.id,
    resources.us_core_care_experience_preference_to_json(resource),
    resources.RtObservation,
    resources.us_core_care_experience_preference_decoder(),
    client,
  )
}

pub fn us_core_care_experience_preference_delete(
  resource: resources.UsCoreCareExperiencePreference,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_careplan_create(
  resource: resources.UsCoreCareplan,
  client: FhirClient,
) -> Result(resources.UsCoreCareplan, Err) {
  any_create(
    resources.us_core_careplan_to_json(resource),
    resources.RtCareplan,
    resources.us_core_careplan_decoder(),
    client,
  )
}

pub fn us_core_careplan_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreCareplan, Err) {
  any_read(
    id,
    client,
    resources.RtCareplan,
    resources.us_core_careplan_decoder(),
  )
}

pub fn us_core_careplan_update(
  resource: resources.UsCoreCareplan,
  client: FhirClient,
) -> Result(resources.UsCoreCareplan, Err) {
  any_update(
    resource.id,
    resources.us_core_careplan_to_json(resource),
    resources.RtCareplan,
    resources.us_core_careplan_decoder(),
    client,
  )
}

pub fn us_core_careplan_delete(
  resource: resources.UsCoreCareplan,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCareplan, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_careteam_create(
  resource: resources.UsCoreCareteam,
  client: FhirClient,
) -> Result(resources.UsCoreCareteam, Err) {
  any_create(
    resources.us_core_careteam_to_json(resource),
    resources.RtCareteam,
    resources.us_core_careteam_decoder(),
    client,
  )
}

pub fn us_core_careteam_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreCareteam, Err) {
  any_read(
    id,
    client,
    resources.RtCareteam,
    resources.us_core_careteam_decoder(),
  )
}

pub fn us_core_careteam_update(
  resource: resources.UsCoreCareteam,
  client: FhirClient,
) -> Result(resources.UsCoreCareteam, Err) {
  any_update(
    resource.id,
    resources.us_core_careteam_to_json(resource),
    resources.RtCareteam,
    resources.us_core_careteam_decoder(),
    client,
  )
}

pub fn us_core_careteam_delete(
  resource: resources.UsCoreCareteam,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCareteam, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_condition_encounter_diagnosis_create(
  resource: resources.UsCoreConditionEncounterDiagnosis,
  client: FhirClient,
) -> Result(resources.UsCoreConditionEncounterDiagnosis, Err) {
  any_create(
    resources.us_core_condition_encounter_diagnosis_to_json(resource),
    resources.RtCondition,
    resources.us_core_condition_encounter_diagnosis_decoder(),
    client,
  )
}

pub fn us_core_condition_encounter_diagnosis_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreConditionEncounterDiagnosis, Err) {
  any_read(
    id,
    client,
    resources.RtCondition,
    resources.us_core_condition_encounter_diagnosis_decoder(),
  )
}

pub fn us_core_condition_encounter_diagnosis_update(
  resource: resources.UsCoreConditionEncounterDiagnosis,
  client: FhirClient,
) -> Result(resources.UsCoreConditionEncounterDiagnosis, Err) {
  any_update(
    resource.id,
    resources.us_core_condition_encounter_diagnosis_to_json(resource),
    resources.RtCondition,
    resources.us_core_condition_encounter_diagnosis_decoder(),
    client,
  )
}

pub fn us_core_condition_encounter_diagnosis_delete(
  resource: resources.UsCoreConditionEncounterDiagnosis,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCondition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_condition_problems_health_concerns_create(
  resource: resources.UsCoreConditionProblemsHealthConcerns,
  client: FhirClient,
) -> Result(resources.UsCoreConditionProblemsHealthConcerns, Err) {
  any_create(
    resources.us_core_condition_problems_health_concerns_to_json(resource),
    resources.RtCondition,
    resources.us_core_condition_problems_health_concerns_decoder(),
    client,
  )
}

pub fn us_core_condition_problems_health_concerns_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreConditionProblemsHealthConcerns, Err) {
  any_read(
    id,
    client,
    resources.RtCondition,
    resources.us_core_condition_problems_health_concerns_decoder(),
  )
}

pub fn us_core_condition_problems_health_concerns_update(
  resource: resources.UsCoreConditionProblemsHealthConcerns,
  client: FhirClient,
) -> Result(resources.UsCoreConditionProblemsHealthConcerns, Err) {
  any_update(
    resource.id,
    resources.us_core_condition_problems_health_concerns_to_json(resource),
    resources.RtCondition,
    resources.us_core_condition_problems_health_concerns_decoder(),
    client,
  )
}

pub fn us_core_condition_problems_health_concerns_delete(
  resource: resources.UsCoreConditionProblemsHealthConcerns,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCondition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_coverage_create(
  resource: resources.UsCoreCoverage,
  client: FhirClient,
) -> Result(resources.UsCoreCoverage, Err) {
  any_create(
    resources.us_core_coverage_to_json(resource),
    resources.RtCoverage,
    resources.us_core_coverage_decoder(),
    client,
  )
}

pub fn us_core_coverage_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreCoverage, Err) {
  any_read(
    id,
    client,
    resources.RtCoverage,
    resources.us_core_coverage_decoder(),
  )
}

pub fn us_core_coverage_update(
  resource: resources.UsCoreCoverage,
  client: FhirClient,
) -> Result(resources.UsCoreCoverage, Err) {
  any_update(
    resource.id,
    resources.us_core_coverage_to_json(resource),
    resources.RtCoverage,
    resources.us_core_coverage_decoder(),
    client,
  )
}

pub fn us_core_coverage_delete(
  resource: resources.UsCoreCoverage,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCoverage, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_diagnosticreport_lab_create(
  resource: resources.UsCoreDiagnosticreportLab,
  client: FhirClient,
) -> Result(resources.UsCoreDiagnosticreportLab, Err) {
  any_create(
    resources.us_core_diagnosticreport_lab_to_json(resource),
    resources.RtDiagnosticreport,
    resources.us_core_diagnosticreport_lab_decoder(),
    client,
  )
}

pub fn us_core_diagnosticreport_lab_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreDiagnosticreportLab, Err) {
  any_read(
    id,
    client,
    resources.RtDiagnosticreport,
    resources.us_core_diagnosticreport_lab_decoder(),
  )
}

pub fn us_core_diagnosticreport_lab_update(
  resource: resources.UsCoreDiagnosticreportLab,
  client: FhirClient,
) -> Result(resources.UsCoreDiagnosticreportLab, Err) {
  any_update(
    resource.id,
    resources.us_core_diagnosticreport_lab_to_json(resource),
    resources.RtDiagnosticreport,
    resources.us_core_diagnosticreport_lab_decoder(),
    client,
  )
}

pub fn us_core_diagnosticreport_lab_delete(
  resource: resources.UsCoreDiagnosticreportLab,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtDiagnosticreport, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_diagnosticreport_note_create(
  resource: resources.UsCoreDiagnosticreportNote,
  client: FhirClient,
) -> Result(resources.UsCoreDiagnosticreportNote, Err) {
  any_create(
    resources.us_core_diagnosticreport_note_to_json(resource),
    resources.RtDiagnosticreport,
    resources.us_core_diagnosticreport_note_decoder(),
    client,
  )
}

pub fn us_core_diagnosticreport_note_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreDiagnosticreportNote, Err) {
  any_read(
    id,
    client,
    resources.RtDiagnosticreport,
    resources.us_core_diagnosticreport_note_decoder(),
  )
}

pub fn us_core_diagnosticreport_note_update(
  resource: resources.UsCoreDiagnosticreportNote,
  client: FhirClient,
) -> Result(resources.UsCoreDiagnosticreportNote, Err) {
  any_update(
    resource.id,
    resources.us_core_diagnosticreport_note_to_json(resource),
    resources.RtDiagnosticreport,
    resources.us_core_diagnosticreport_note_decoder(),
    client,
  )
}

pub fn us_core_diagnosticreport_note_delete(
  resource: resources.UsCoreDiagnosticreportNote,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtDiagnosticreport, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_documentreference_create(
  resource: resources.UsCoreDocumentreference,
  client: FhirClient,
) -> Result(resources.UsCoreDocumentreference, Err) {
  any_create(
    resources.us_core_documentreference_to_json(resource),
    resources.RtDocumentreference,
    resources.us_core_documentreference_decoder(),
    client,
  )
}

pub fn us_core_documentreference_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreDocumentreference, Err) {
  any_read(
    id,
    client,
    resources.RtDocumentreference,
    resources.us_core_documentreference_decoder(),
  )
}

pub fn us_core_documentreference_update(
  resource: resources.UsCoreDocumentreference,
  client: FhirClient,
) -> Result(resources.UsCoreDocumentreference, Err) {
  any_update(
    resource.id,
    resources.us_core_documentreference_to_json(resource),
    resources.RtDocumentreference,
    resources.us_core_documentreference_decoder(),
    client,
  )
}

pub fn us_core_documentreference_delete(
  resource: resources.UsCoreDocumentreference,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtDocumentreference, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_encounter_create(
  resource: resources.UsCoreEncounter,
  client: FhirClient,
) -> Result(resources.UsCoreEncounter, Err) {
  any_create(
    resources.us_core_encounter_to_json(resource),
    resources.RtEncounter,
    resources.us_core_encounter_decoder(),
    client,
  )
}

pub fn us_core_encounter_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreEncounter, Err) {
  any_read(
    id,
    client,
    resources.RtEncounter,
    resources.us_core_encounter_decoder(),
  )
}

pub fn us_core_encounter_update(
  resource: resources.UsCoreEncounter,
  client: FhirClient,
) -> Result(resources.UsCoreEncounter, Err) {
  any_update(
    resource.id,
    resources.us_core_encounter_to_json(resource),
    resources.RtEncounter,
    resources.us_core_encounter_decoder(),
    client,
  )
}

pub fn us_core_encounter_delete(
  resource: resources.UsCoreEncounter,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtEncounter, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_goal_create(
  resource: resources.UsCoreGoal,
  client: FhirClient,
) -> Result(resources.UsCoreGoal, Err) {
  any_create(
    resources.us_core_goal_to_json(resource),
    resources.RtGoal,
    resources.us_core_goal_decoder(),
    client,
  )
}

pub fn us_core_goal_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreGoal, Err) {
  any_read(id, client, resources.RtGoal, resources.us_core_goal_decoder())
}

pub fn us_core_goal_update(
  resource: resources.UsCoreGoal,
  client: FhirClient,
) -> Result(resources.UsCoreGoal, Err) {
  any_update(
    resource.id,
    resources.us_core_goal_to_json(resource),
    resources.RtGoal,
    resources.us_core_goal_decoder(),
    client,
  )
}

pub fn us_core_goal_delete(
  resource: resources.UsCoreGoal,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtGoal, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_head_circumference_create(
  resource: resources.UsCoreHeadCircumference,
  client: FhirClient,
) -> Result(resources.UsCoreHeadCircumference, Err) {
  any_create(
    resources.us_core_head_circumference_to_json(resource),
    resources.RtObservation,
    resources.us_core_head_circumference_decoder(),
    client,
  )
}

pub fn us_core_head_circumference_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreHeadCircumference, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_head_circumference_decoder(),
  )
}

pub fn us_core_head_circumference_update(
  resource: resources.UsCoreHeadCircumference,
  client: FhirClient,
) -> Result(resources.UsCoreHeadCircumference, Err) {
  any_update(
    resource.id,
    resources.us_core_head_circumference_to_json(resource),
    resources.RtObservation,
    resources.us_core_head_circumference_decoder(),
    client,
  )
}

pub fn us_core_head_circumference_delete(
  resource: resources.UsCoreHeadCircumference,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_heart_rate_create(
  resource: resources.UsCoreHeartRate,
  client: FhirClient,
) -> Result(resources.UsCoreHeartRate, Err) {
  any_create(
    resources.us_core_heart_rate_to_json(resource),
    resources.RtObservation,
    resources.us_core_heart_rate_decoder(),
    client,
  )
}

pub fn us_core_heart_rate_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreHeartRate, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_heart_rate_decoder(),
  )
}

pub fn us_core_heart_rate_update(
  resource: resources.UsCoreHeartRate,
  client: FhirClient,
) -> Result(resources.UsCoreHeartRate, Err) {
  any_update(
    resource.id,
    resources.us_core_heart_rate_to_json(resource),
    resources.RtObservation,
    resources.us_core_heart_rate_decoder(),
    client,
  )
}

pub fn us_core_heart_rate_delete(
  resource: resources.UsCoreHeartRate,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_immunization_create(
  resource: resources.UsCoreImmunization,
  client: FhirClient,
) -> Result(resources.UsCoreImmunization, Err) {
  any_create(
    resources.us_core_immunization_to_json(resource),
    resources.RtImmunization,
    resources.us_core_immunization_decoder(),
    client,
  )
}

pub fn us_core_immunization_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreImmunization, Err) {
  any_read(
    id,
    client,
    resources.RtImmunization,
    resources.us_core_immunization_decoder(),
  )
}

pub fn us_core_immunization_update(
  resource: resources.UsCoreImmunization,
  client: FhirClient,
) -> Result(resources.UsCoreImmunization, Err) {
  any_update(
    resource.id,
    resources.us_core_immunization_to_json(resource),
    resources.RtImmunization,
    resources.us_core_immunization_decoder(),
    client,
  )
}

pub fn us_core_immunization_delete(
  resource: resources.UsCoreImmunization,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtImmunization, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_implantable_device_create(
  resource: resources.UsCoreImplantableDevice,
  client: FhirClient,
) -> Result(resources.UsCoreImplantableDevice, Err) {
  any_create(
    resources.us_core_implantable_device_to_json(resource),
    resources.RtDevice,
    resources.us_core_implantable_device_decoder(),
    client,
  )
}

pub fn us_core_implantable_device_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreImplantableDevice, Err) {
  any_read(
    id,
    client,
    resources.RtDevice,
    resources.us_core_implantable_device_decoder(),
  )
}

pub fn us_core_implantable_device_update(
  resource: resources.UsCoreImplantableDevice,
  client: FhirClient,
) -> Result(resources.UsCoreImplantableDevice, Err) {
  any_update(
    resource.id,
    resources.us_core_implantable_device_to_json(resource),
    resources.RtDevice,
    resources.us_core_implantable_device_decoder(),
    client,
  )
}

pub fn us_core_implantable_device_delete(
  resource: resources.UsCoreImplantableDevice,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtDevice, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_location_create(
  resource: resources.UsCoreLocation,
  client: FhirClient,
) -> Result(resources.UsCoreLocation, Err) {
  any_create(
    resources.us_core_location_to_json(resource),
    resources.RtLocation,
    resources.us_core_location_decoder(),
    client,
  )
}

pub fn us_core_location_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreLocation, Err) {
  any_read(
    id,
    client,
    resources.RtLocation,
    resources.us_core_location_decoder(),
  )
}

pub fn us_core_location_update(
  resource: resources.UsCoreLocation,
  client: FhirClient,
) -> Result(resources.UsCoreLocation, Err) {
  any_update(
    resource.id,
    resources.us_core_location_to_json(resource),
    resources.RtLocation,
    resources.us_core_location_decoder(),
    client,
  )
}

pub fn us_core_location_delete(
  resource: resources.UsCoreLocation,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtLocation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_medication_create(
  resource: resources.UsCoreMedication,
  client: FhirClient,
) -> Result(resources.UsCoreMedication, Err) {
  any_create(
    resources.us_core_medication_to_json(resource),
    resources.RtMedication,
    resources.us_core_medication_decoder(),
    client,
  )
}

pub fn us_core_medication_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreMedication, Err) {
  any_read(
    id,
    client,
    resources.RtMedication,
    resources.us_core_medication_decoder(),
  )
}

pub fn us_core_medication_update(
  resource: resources.UsCoreMedication,
  client: FhirClient,
) -> Result(resources.UsCoreMedication, Err) {
  any_update(
    resource.id,
    resources.us_core_medication_to_json(resource),
    resources.RtMedication,
    resources.us_core_medication_decoder(),
    client,
  )
}

pub fn us_core_medication_delete(
  resource: resources.UsCoreMedication,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedication, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_medicationdispense_create(
  resource: resources.UsCoreMedicationdispense,
  client: FhirClient,
) -> Result(resources.UsCoreMedicationdispense, Err) {
  any_create(
    resources.us_core_medicationdispense_to_json(resource),
    resources.RtMedicationdispense,
    resources.us_core_medicationdispense_decoder(),
    client,
  )
}

pub fn us_core_medicationdispense_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreMedicationdispense, Err) {
  any_read(
    id,
    client,
    resources.RtMedicationdispense,
    resources.us_core_medicationdispense_decoder(),
  )
}

pub fn us_core_medicationdispense_update(
  resource: resources.UsCoreMedicationdispense,
  client: FhirClient,
) -> Result(resources.UsCoreMedicationdispense, Err) {
  any_update(
    resource.id,
    resources.us_core_medicationdispense_to_json(resource),
    resources.RtMedicationdispense,
    resources.us_core_medicationdispense_decoder(),
    client,
  )
}

pub fn us_core_medicationdispense_delete(
  resource: resources.UsCoreMedicationdispense,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedicationdispense, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_medicationrequest_create(
  resource: resources.UsCoreMedicationrequest,
  client: FhirClient,
) -> Result(resources.UsCoreMedicationrequest, Err) {
  any_create(
    resources.us_core_medicationrequest_to_json(resource),
    resources.RtMedicationrequest,
    resources.us_core_medicationrequest_decoder(),
    client,
  )
}

pub fn us_core_medicationrequest_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreMedicationrequest, Err) {
  any_read(
    id,
    client,
    resources.RtMedicationrequest,
    resources.us_core_medicationrequest_decoder(),
  )
}

pub fn us_core_medicationrequest_update(
  resource: resources.UsCoreMedicationrequest,
  client: FhirClient,
) -> Result(resources.UsCoreMedicationrequest, Err) {
  any_update(
    resource.id,
    resources.us_core_medicationrequest_to_json(resource),
    resources.RtMedicationrequest,
    resources.us_core_medicationrequest_decoder(),
    client,
  )
}

pub fn us_core_medicationrequest_delete(
  resource: resources.UsCoreMedicationrequest,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedicationrequest, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_observation_clinical_result_create(
  resource: resources.UsCoreObservationClinicalResult,
  client: FhirClient,
) -> Result(resources.UsCoreObservationClinicalResult, Err) {
  any_create(
    resources.us_core_observation_clinical_result_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_clinical_result_decoder(),
    client,
  )
}

pub fn us_core_observation_clinical_result_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreObservationClinicalResult, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_observation_clinical_result_decoder(),
  )
}

pub fn us_core_observation_clinical_result_update(
  resource: resources.UsCoreObservationClinicalResult,
  client: FhirClient,
) -> Result(resources.UsCoreObservationClinicalResult, Err) {
  any_update(
    resource.id,
    resources.us_core_observation_clinical_result_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_clinical_result_decoder(),
    client,
  )
}

pub fn us_core_observation_clinical_result_delete(
  resource: resources.UsCoreObservationClinicalResult,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_observation_lab_create(
  resource: resources.UsCoreObservationLab,
  client: FhirClient,
) -> Result(resources.UsCoreObservationLab, Err) {
  any_create(
    resources.us_core_observation_lab_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_lab_decoder(),
    client,
  )
}

pub fn us_core_observation_lab_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreObservationLab, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_observation_lab_decoder(),
  )
}

pub fn us_core_observation_lab_update(
  resource: resources.UsCoreObservationLab,
  client: FhirClient,
) -> Result(resources.UsCoreObservationLab, Err) {
  any_update(
    resource.id,
    resources.us_core_observation_lab_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_lab_decoder(),
    client,
  )
}

pub fn us_core_observation_lab_delete(
  resource: resources.UsCoreObservationLab,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_observation_occupation_create(
  resource: resources.UsCoreObservationOccupation,
  client: FhirClient,
) -> Result(resources.UsCoreObservationOccupation, Err) {
  any_create(
    resources.us_core_observation_occupation_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_occupation_decoder(),
    client,
  )
}

pub fn us_core_observation_occupation_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreObservationOccupation, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_observation_occupation_decoder(),
  )
}

pub fn us_core_observation_occupation_update(
  resource: resources.UsCoreObservationOccupation,
  client: FhirClient,
) -> Result(resources.UsCoreObservationOccupation, Err) {
  any_update(
    resource.id,
    resources.us_core_observation_occupation_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_occupation_decoder(),
    client,
  )
}

pub fn us_core_observation_occupation_delete(
  resource: resources.UsCoreObservationOccupation,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_observation_pregnancyintent_create(
  resource: resources.UsCoreObservationPregnancyintent,
  client: FhirClient,
) -> Result(resources.UsCoreObservationPregnancyintent, Err) {
  any_create(
    resources.us_core_observation_pregnancyintent_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_pregnancyintent_decoder(),
    client,
  )
}

pub fn us_core_observation_pregnancyintent_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreObservationPregnancyintent, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_observation_pregnancyintent_decoder(),
  )
}

pub fn us_core_observation_pregnancyintent_update(
  resource: resources.UsCoreObservationPregnancyintent,
  client: FhirClient,
) -> Result(resources.UsCoreObservationPregnancyintent, Err) {
  any_update(
    resource.id,
    resources.us_core_observation_pregnancyintent_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_pregnancyintent_decoder(),
    client,
  )
}

pub fn us_core_observation_pregnancyintent_delete(
  resource: resources.UsCoreObservationPregnancyintent,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_observation_pregnancystatus_create(
  resource: resources.UsCoreObservationPregnancystatus,
  client: FhirClient,
) -> Result(resources.UsCoreObservationPregnancystatus, Err) {
  any_create(
    resources.us_core_observation_pregnancystatus_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_pregnancystatus_decoder(),
    client,
  )
}

pub fn us_core_observation_pregnancystatus_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreObservationPregnancystatus, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_observation_pregnancystatus_decoder(),
  )
}

pub fn us_core_observation_pregnancystatus_update(
  resource: resources.UsCoreObservationPregnancystatus,
  client: FhirClient,
) -> Result(resources.UsCoreObservationPregnancystatus, Err) {
  any_update(
    resource.id,
    resources.us_core_observation_pregnancystatus_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_pregnancystatus_decoder(),
    client,
  )
}

pub fn us_core_observation_pregnancystatus_delete(
  resource: resources.UsCoreObservationPregnancystatus,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_observation_screening_assessment_create(
  resource: resources.UsCoreObservationScreeningAssessment,
  client: FhirClient,
) -> Result(resources.UsCoreObservationScreeningAssessment, Err) {
  any_create(
    resources.us_core_observation_screening_assessment_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_screening_assessment_decoder(),
    client,
  )
}

pub fn us_core_observation_screening_assessment_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreObservationScreeningAssessment, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_observation_screening_assessment_decoder(),
  )
}

pub fn us_core_observation_screening_assessment_update(
  resource: resources.UsCoreObservationScreeningAssessment,
  client: FhirClient,
) -> Result(resources.UsCoreObservationScreeningAssessment, Err) {
  any_update(
    resource.id,
    resources.us_core_observation_screening_assessment_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_screening_assessment_decoder(),
    client,
  )
}

pub fn us_core_observation_screening_assessment_delete(
  resource: resources.UsCoreObservationScreeningAssessment,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_observation_sexual_orientation_create(
  resource: resources.UsCoreObservationSexualOrientation,
  client: FhirClient,
) -> Result(resources.UsCoreObservationSexualOrientation, Err) {
  any_create(
    resources.us_core_observation_sexual_orientation_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_sexual_orientation_decoder(),
    client,
  )
}

pub fn us_core_observation_sexual_orientation_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreObservationSexualOrientation, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_observation_sexual_orientation_decoder(),
  )
}

pub fn us_core_observation_sexual_orientation_update(
  resource: resources.UsCoreObservationSexualOrientation,
  client: FhirClient,
) -> Result(resources.UsCoreObservationSexualOrientation, Err) {
  any_update(
    resource.id,
    resources.us_core_observation_sexual_orientation_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_sexual_orientation_decoder(),
    client,
  )
}

pub fn us_core_observation_sexual_orientation_delete(
  resource: resources.UsCoreObservationSexualOrientation,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_organization_create(
  resource: resources.UsCoreOrganization,
  client: FhirClient,
) -> Result(resources.UsCoreOrganization, Err) {
  any_create(
    resources.us_core_organization_to_json(resource),
    resources.RtOrganization,
    resources.us_core_organization_decoder(),
    client,
  )
}

pub fn us_core_organization_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreOrganization, Err) {
  any_read(
    id,
    client,
    resources.RtOrganization,
    resources.us_core_organization_decoder(),
  )
}

pub fn us_core_organization_update(
  resource: resources.UsCoreOrganization,
  client: FhirClient,
) -> Result(resources.UsCoreOrganization, Err) {
  any_update(
    resource.id,
    resources.us_core_organization_to_json(resource),
    resources.RtOrganization,
    resources.us_core_organization_decoder(),
    client,
  )
}

pub fn us_core_organization_delete(
  resource: resources.UsCoreOrganization,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtOrganization, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_patient_create(
  resource: resources.UsCorePatient,
  client: FhirClient,
) -> Result(resources.UsCorePatient, Err) {
  any_create(
    resources.us_core_patient_to_json(resource),
    resources.RtPatient,
    resources.us_core_patient_decoder(),
    client,
  )
}

pub fn us_core_patient_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCorePatient, Err) {
  any_read(id, client, resources.RtPatient, resources.us_core_patient_decoder())
}

pub fn us_core_patient_update(
  resource: resources.UsCorePatient,
  client: FhirClient,
) -> Result(resources.UsCorePatient, Err) {
  any_update(
    resource.id,
    resources.us_core_patient_to_json(resource),
    resources.RtPatient,
    resources.us_core_patient_decoder(),
    client,
  )
}

pub fn us_core_patient_delete(
  resource: resources.UsCorePatient,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtPatient, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_practitioner_create(
  resource: resources.UsCorePractitioner,
  client: FhirClient,
) -> Result(resources.UsCorePractitioner, Err) {
  any_create(
    resources.us_core_practitioner_to_json(resource),
    resources.RtPractitioner,
    resources.us_core_practitioner_decoder(),
    client,
  )
}

pub fn us_core_practitioner_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCorePractitioner, Err) {
  any_read(
    id,
    client,
    resources.RtPractitioner,
    resources.us_core_practitioner_decoder(),
  )
}

pub fn us_core_practitioner_update(
  resource: resources.UsCorePractitioner,
  client: FhirClient,
) -> Result(resources.UsCorePractitioner, Err) {
  any_update(
    resource.id,
    resources.us_core_practitioner_to_json(resource),
    resources.RtPractitioner,
    resources.us_core_practitioner_decoder(),
    client,
  )
}

pub fn us_core_practitioner_delete(
  resource: resources.UsCorePractitioner,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtPractitioner, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_practitionerrole_create(
  resource: resources.UsCorePractitionerrole,
  client: FhirClient,
) -> Result(resources.UsCorePractitionerrole, Err) {
  any_create(
    resources.us_core_practitionerrole_to_json(resource),
    resources.RtPractitionerrole,
    resources.us_core_practitionerrole_decoder(),
    client,
  )
}

pub fn us_core_practitionerrole_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCorePractitionerrole, Err) {
  any_read(
    id,
    client,
    resources.RtPractitionerrole,
    resources.us_core_practitionerrole_decoder(),
  )
}

pub fn us_core_practitionerrole_update(
  resource: resources.UsCorePractitionerrole,
  client: FhirClient,
) -> Result(resources.UsCorePractitionerrole, Err) {
  any_update(
    resource.id,
    resources.us_core_practitionerrole_to_json(resource),
    resources.RtPractitionerrole,
    resources.us_core_practitionerrole_decoder(),
    client,
  )
}

pub fn us_core_practitionerrole_delete(
  resource: resources.UsCorePractitionerrole,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtPractitionerrole, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_procedure_create(
  resource: resources.UsCoreProcedure,
  client: FhirClient,
) -> Result(resources.UsCoreProcedure, Err) {
  any_create(
    resources.us_core_procedure_to_json(resource),
    resources.RtProcedure,
    resources.us_core_procedure_decoder(),
    client,
  )
}

pub fn us_core_procedure_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreProcedure, Err) {
  any_read(
    id,
    client,
    resources.RtProcedure,
    resources.us_core_procedure_decoder(),
  )
}

pub fn us_core_procedure_update(
  resource: resources.UsCoreProcedure,
  client: FhirClient,
) -> Result(resources.UsCoreProcedure, Err) {
  any_update(
    resource.id,
    resources.us_core_procedure_to_json(resource),
    resources.RtProcedure,
    resources.us_core_procedure_decoder(),
    client,
  )
}

pub fn us_core_procedure_delete(
  resource: resources.UsCoreProcedure,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtProcedure, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_provenance_create(
  resource: resources.UsCoreProvenance,
  client: FhirClient,
) -> Result(resources.UsCoreProvenance, Err) {
  any_create(
    resources.us_core_provenance_to_json(resource),
    resources.RtProvenance,
    resources.us_core_provenance_decoder(),
    client,
  )
}

pub fn us_core_provenance_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreProvenance, Err) {
  any_read(
    id,
    client,
    resources.RtProvenance,
    resources.us_core_provenance_decoder(),
  )
}

pub fn us_core_provenance_update(
  resource: resources.UsCoreProvenance,
  client: FhirClient,
) -> Result(resources.UsCoreProvenance, Err) {
  any_update(
    resource.id,
    resources.us_core_provenance_to_json(resource),
    resources.RtProvenance,
    resources.us_core_provenance_decoder(),
    client,
  )
}

pub fn us_core_provenance_delete(
  resource: resources.UsCoreProvenance,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtProvenance, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_pulse_oximetry_create(
  resource: resources.UsCorePulseOximetry,
  client: FhirClient,
) -> Result(resources.UsCorePulseOximetry, Err) {
  any_create(
    resources.us_core_pulse_oximetry_to_json(resource),
    resources.RtObservation,
    resources.us_core_pulse_oximetry_decoder(),
    client,
  )
}

pub fn us_core_pulse_oximetry_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCorePulseOximetry, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_pulse_oximetry_decoder(),
  )
}

pub fn us_core_pulse_oximetry_update(
  resource: resources.UsCorePulseOximetry,
  client: FhirClient,
) -> Result(resources.UsCorePulseOximetry, Err) {
  any_update(
    resource.id,
    resources.us_core_pulse_oximetry_to_json(resource),
    resources.RtObservation,
    resources.us_core_pulse_oximetry_decoder(),
    client,
  )
}

pub fn us_core_pulse_oximetry_delete(
  resource: resources.UsCorePulseOximetry,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_questionnaireresponse_create(
  resource: resources.UsCoreQuestionnaireresponse,
  client: FhirClient,
) -> Result(resources.UsCoreQuestionnaireresponse, Err) {
  any_create(
    resources.us_core_questionnaireresponse_to_json(resource),
    resources.RtQuestionnaireresponse,
    resources.us_core_questionnaireresponse_decoder(),
    client,
  )
}

pub fn us_core_questionnaireresponse_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreQuestionnaireresponse, Err) {
  any_read(
    id,
    client,
    resources.RtQuestionnaireresponse,
    resources.us_core_questionnaireresponse_decoder(),
  )
}

pub fn us_core_questionnaireresponse_update(
  resource: resources.UsCoreQuestionnaireresponse,
  client: FhirClient,
) -> Result(resources.UsCoreQuestionnaireresponse, Err) {
  any_update(
    resource.id,
    resources.us_core_questionnaireresponse_to_json(resource),
    resources.RtQuestionnaireresponse,
    resources.us_core_questionnaireresponse_decoder(),
    client,
  )
}

pub fn us_core_questionnaireresponse_delete(
  resource: resources.UsCoreQuestionnaireresponse,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtQuestionnaireresponse, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_relatedperson_create(
  resource: resources.UsCoreRelatedperson,
  client: FhirClient,
) -> Result(resources.UsCoreRelatedperson, Err) {
  any_create(
    resources.us_core_relatedperson_to_json(resource),
    resources.RtRelatedperson,
    resources.us_core_relatedperson_decoder(),
    client,
  )
}

pub fn us_core_relatedperson_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreRelatedperson, Err) {
  any_read(
    id,
    client,
    resources.RtRelatedperson,
    resources.us_core_relatedperson_decoder(),
  )
}

pub fn us_core_relatedperson_update(
  resource: resources.UsCoreRelatedperson,
  client: FhirClient,
) -> Result(resources.UsCoreRelatedperson, Err) {
  any_update(
    resource.id,
    resources.us_core_relatedperson_to_json(resource),
    resources.RtRelatedperson,
    resources.us_core_relatedperson_decoder(),
    client,
  )
}

pub fn us_core_relatedperson_delete(
  resource: resources.UsCoreRelatedperson,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtRelatedperson, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_respiratory_rate_create(
  resource: resources.UsCoreRespiratoryRate,
  client: FhirClient,
) -> Result(resources.UsCoreRespiratoryRate, Err) {
  any_create(
    resources.us_core_respiratory_rate_to_json(resource),
    resources.RtObservation,
    resources.us_core_respiratory_rate_decoder(),
    client,
  )
}

pub fn us_core_respiratory_rate_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreRespiratoryRate, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_respiratory_rate_decoder(),
  )
}

pub fn us_core_respiratory_rate_update(
  resource: resources.UsCoreRespiratoryRate,
  client: FhirClient,
) -> Result(resources.UsCoreRespiratoryRate, Err) {
  any_update(
    resource.id,
    resources.us_core_respiratory_rate_to_json(resource),
    resources.RtObservation,
    resources.us_core_respiratory_rate_decoder(),
    client,
  )
}

pub fn us_core_respiratory_rate_delete(
  resource: resources.UsCoreRespiratoryRate,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_servicerequest_create(
  resource: resources.UsCoreServicerequest,
  client: FhirClient,
) -> Result(resources.UsCoreServicerequest, Err) {
  any_create(
    resources.us_core_servicerequest_to_json(resource),
    resources.RtServicerequest,
    resources.us_core_servicerequest_decoder(),
    client,
  )
}

pub fn us_core_servicerequest_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreServicerequest, Err) {
  any_read(
    id,
    client,
    resources.RtServicerequest,
    resources.us_core_servicerequest_decoder(),
  )
}

pub fn us_core_servicerequest_update(
  resource: resources.UsCoreServicerequest,
  client: FhirClient,
) -> Result(resources.UsCoreServicerequest, Err) {
  any_update(
    resource.id,
    resources.us_core_servicerequest_to_json(resource),
    resources.RtServicerequest,
    resources.us_core_servicerequest_decoder(),
    client,
  )
}

pub fn us_core_servicerequest_delete(
  resource: resources.UsCoreServicerequest,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtServicerequest, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_simple_observation_create(
  resource: resources.UsCoreSimpleObservation,
  client: FhirClient,
) -> Result(resources.UsCoreSimpleObservation, Err) {
  any_create(
    resources.us_core_simple_observation_to_json(resource),
    resources.RtObservation,
    resources.us_core_simple_observation_decoder(),
    client,
  )
}

pub fn us_core_simple_observation_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreSimpleObservation, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_simple_observation_decoder(),
  )
}

pub fn us_core_simple_observation_update(
  resource: resources.UsCoreSimpleObservation,
  client: FhirClient,
) -> Result(resources.UsCoreSimpleObservation, Err) {
  any_update(
    resource.id,
    resources.us_core_simple_observation_to_json(resource),
    resources.RtObservation,
    resources.us_core_simple_observation_decoder(),
    client,
  )
}

pub fn us_core_simple_observation_delete(
  resource: resources.UsCoreSimpleObservation,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_smokingstatus_create(
  resource: resources.UsCoreSmokingstatus,
  client: FhirClient,
) -> Result(resources.UsCoreSmokingstatus, Err) {
  any_create(
    resources.us_core_smokingstatus_to_json(resource),
    resources.RtObservation,
    resources.us_core_smokingstatus_decoder(),
    client,
  )
}

pub fn us_core_smokingstatus_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreSmokingstatus, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_smokingstatus_decoder(),
  )
}

pub fn us_core_smokingstatus_update(
  resource: resources.UsCoreSmokingstatus,
  client: FhirClient,
) -> Result(resources.UsCoreSmokingstatus, Err) {
  any_update(
    resource.id,
    resources.us_core_smokingstatus_to_json(resource),
    resources.RtObservation,
    resources.us_core_smokingstatus_decoder(),
    client,
  )
}

pub fn us_core_smokingstatus_delete(
  resource: resources.UsCoreSmokingstatus,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_specimen_create(
  resource: resources.UsCoreSpecimen,
  client: FhirClient,
) -> Result(resources.UsCoreSpecimen, Err) {
  any_create(
    resources.us_core_specimen_to_json(resource),
    resources.RtSpecimen,
    resources.us_core_specimen_decoder(),
    client,
  )
}

pub fn us_core_specimen_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreSpecimen, Err) {
  any_read(
    id,
    client,
    resources.RtSpecimen,
    resources.us_core_specimen_decoder(),
  )
}

pub fn us_core_specimen_update(
  resource: resources.UsCoreSpecimen,
  client: FhirClient,
) -> Result(resources.UsCoreSpecimen, Err) {
  any_update(
    resource.id,
    resources.us_core_specimen_to_json(resource),
    resources.RtSpecimen,
    resources.us_core_specimen_decoder(),
    client,
  )
}

pub fn us_core_specimen_delete(
  resource: resources.UsCoreSpecimen,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSpecimen, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_treatment_intervention_preference_create(
  resource: resources.UsCoreTreatmentInterventionPreference,
  client: FhirClient,
) -> Result(resources.UsCoreTreatmentInterventionPreference, Err) {
  any_create(
    resources.us_core_treatment_intervention_preference_to_json(resource),
    resources.RtObservation,
    resources.us_core_treatment_intervention_preference_decoder(),
    client,
  )
}

pub fn us_core_treatment_intervention_preference_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreTreatmentInterventionPreference, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_treatment_intervention_preference_decoder(),
  )
}

pub fn us_core_treatment_intervention_preference_update(
  resource: resources.UsCoreTreatmentInterventionPreference,
  client: FhirClient,
) -> Result(resources.UsCoreTreatmentInterventionPreference, Err) {
  any_update(
    resource.id,
    resources.us_core_treatment_intervention_preference_to_json(resource),
    resources.RtObservation,
    resources.us_core_treatment_intervention_preference_decoder(),
    client,
  )
}

pub fn us_core_treatment_intervention_preference_delete(
  resource: resources.UsCoreTreatmentInterventionPreference,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn us_core_vital_signs_create(
  resource: resources.UsCoreVitalSigns,
  client: FhirClient,
) -> Result(resources.UsCoreVitalSigns, Err) {
  any_create(
    resources.us_core_vital_signs_to_json(resource),
    resources.RtObservation,
    resources.us_core_vital_signs_decoder(),
    client,
  )
}

pub fn us_core_vital_signs_read(
  id: String,
  client: FhirClient,
) -> Result(resources.UsCoreVitalSigns, Err) {
  any_read(
    id,
    client,
    resources.RtObservation,
    resources.us_core_vital_signs_decoder(),
  )
}

pub fn us_core_vital_signs_update(
  resource: resources.UsCoreVitalSigns,
  client: FhirClient,
) -> Result(resources.UsCoreVitalSigns, Err) {
  any_update(
    resource.id,
    resources.us_core_vital_signs_to_json(resource),
    resources.RtObservation,
    resources.us_core_vital_signs_decoder(),
    client,
  )
}

pub fn us_core_vital_signs_delete(
  resource: resources.UsCoreVitalSigns,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn bundle_search_bundled(sp: search_params.Bundle, client: FhirClient) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("composition", sp.composition),
    #("type", sp.type_),
    #("message", sp.message),
    #("timestamp", sp.timestamp),
  ])
  |> search_any(resources.RtBundle, client)
}

pub fn bundle_search(
  sp: search_params.Bundle,
  client: FhirClient,
) -> Result(List(resources.Bundle), Err) {
  case bundle_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.bundle)
    Error(error) -> Error(error)
  }
}

pub fn endpoint_search_bundled(sp: search_params.Endpoint, client: FhirClient) {
  search_params.to_string([
    #("payload-type", sp.payload_type),
    #("identifier", sp.identifier),
    #("organization", sp.organization),
    #("connection-type", sp.connection_type),
    #("name", sp.name),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEndpoint, client)
}

pub fn endpoint_search(
  sp: search_params.Endpoint,
  client: FhirClient,
) -> Result(List(resources.Endpoint), Err) {
  case endpoint_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.endpoint)
    Error(error) -> Error(error)
  }
}

pub fn operationoutcome_search_bundled(
  _sp: search_params.Operationoutcome,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtOperationoutcome, client)
}

pub fn operationoutcome_search(
  sp: search_params.Operationoutcome,
  client: FhirClient,
) -> Result(List(resources.Operationoutcome), Err) {
  case operationoutcome_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.operationoutcome)
    Error(error) -> Error(error)
  }
}

pub fn head_occipital_frontal_circumference_percentile_search_bundled(
  sp: search_params.HeadOccipitalFrontalCircumferencePercentile,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn head_occipital_frontal_circumference_percentile_search(
  sp: search_params.HeadOccipitalFrontalCircumferencePercentile,
  client: FhirClient,
) -> Result(List(resources.HeadOccipitalFrontalCircumferencePercentile), Err) {
  case
    head_occipital_frontal_circumference_percentile_search_bundled(sp, client)
  {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.head_occipital_frontal_circumference_percentile,
      )
    Error(error) -> Error(error)
  }
}

pub fn pediatric_bmi_for_age_search_bundled(
  sp: search_params.PediatricBmiForAge,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn pediatric_bmi_for_age_search(
  sp: search_params.PediatricBmiForAge,
  client: FhirClient,
) -> Result(List(resources.PediatricBmiForAge), Err) {
  case pediatric_bmi_for_age_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.pediatric_bmi_for_age)
    Error(error) -> Error(error)
  }
}

pub fn pediatric_weight_for_height_search_bundled(
  sp: search_params.PediatricWeightForHeight,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn pediatric_weight_for_height_search(
  sp: search_params.PediatricWeightForHeight,
  client: FhirClient,
) -> Result(List(resources.PediatricWeightForHeight), Err) {
  case pediatric_weight_for_height_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.pediatric_weight_for_height,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_allergyintolerance_search_bundled(
  sp: search_params.UsCoreAllergyintolerance,
  client: FhirClient,
) {
  search_params.to_string([
    #("clinical-status", sp.clinical_status),
    #("patient", sp.patient),
  ])
  |> search_any(resources.RtAllergyintolerance, client)
}

pub fn us_core_allergyintolerance_search(
  sp: search_params.UsCoreAllergyintolerance,
  client: FhirClient,
) -> Result(List(resources.UsCoreAllergyintolerance), Err) {
  case us_core_allergyintolerance_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_allergyintolerance,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_average_blood_pressure_search_bundled(
  sp: search_params.UsCoreAverageBloodPressure,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_average_blood_pressure_search(
  sp: search_params.UsCoreAverageBloodPressure,
  client: FhirClient,
) -> Result(List(resources.UsCoreAverageBloodPressure), Err) {
  case us_core_average_blood_pressure_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_average_blood_pressure,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_blood_pressure_search_bundled(
  sp: search_params.UsCoreBloodPressure,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_blood_pressure_search(
  sp: search_params.UsCoreBloodPressure,
  client: FhirClient,
) -> Result(List(resources.UsCoreBloodPressure), Err) {
  case us_core_blood_pressure_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_blood_pressure)
    Error(error) -> Error(error)
  }
}

pub fn us_core_bmi_search_bundled(
  sp: search_params.UsCoreBmi,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_bmi_search(
  sp: search_params.UsCoreBmi,
  client: FhirClient,
) -> Result(List(resources.UsCoreBmi), Err) {
  case us_core_bmi_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_bmi)
    Error(error) -> Error(error)
  }
}

pub fn us_core_body_height_search_bundled(
  sp: search_params.UsCoreBodyHeight,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_body_height_search(
  sp: search_params.UsCoreBodyHeight,
  client: FhirClient,
) -> Result(List(resources.UsCoreBodyHeight), Err) {
  case us_core_body_height_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_body_height)
    Error(error) -> Error(error)
  }
}

pub fn us_core_body_temperature_search_bundled(
  sp: search_params.UsCoreBodyTemperature,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_body_temperature_search(
  sp: search_params.UsCoreBodyTemperature,
  client: FhirClient,
) -> Result(List(resources.UsCoreBodyTemperature), Err) {
  case us_core_body_temperature_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_body_temperature,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_body_weight_search_bundled(
  sp: search_params.UsCoreBodyWeight,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_body_weight_search(
  sp: search_params.UsCoreBodyWeight,
  client: FhirClient,
) -> Result(List(resources.UsCoreBodyWeight), Err) {
  case us_core_body_weight_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_body_weight)
    Error(error) -> Error(error)
  }
}

pub fn us_core_care_experience_preference_search_bundled(
  sp: search_params.UsCoreCareExperiencePreference,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_care_experience_preference_search(
  sp: search_params.UsCoreCareExperiencePreference,
  client: FhirClient,
) -> Result(List(resources.UsCoreCareExperiencePreference), Err) {
  case us_core_care_experience_preference_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_care_experience_preference,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_careplan_search_bundled(
  sp: search_params.UsCoreCareplan,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("date", sp.date),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCareplan, client)
}

pub fn us_core_careplan_search(
  sp: search_params.UsCoreCareplan,
  client: FhirClient,
) -> Result(List(resources.UsCoreCareplan), Err) {
  case us_core_careplan_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_careplan)
    Error(error) -> Error(error)
  }
}

pub fn us_core_careteam_search_bundled(
  sp: search_params.UsCoreCareteam,
  client: FhirClient,
) {
  search_params.to_string([
    #("patient", sp.patient),
    #("role", sp.role),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCareteam, client)
}

pub fn us_core_careteam_search(
  sp: search_params.UsCoreCareteam,
  client: FhirClient,
) -> Result(List(resources.UsCoreCareteam), Err) {
  case us_core_careteam_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_careteam)
    Error(error) -> Error(error)
  }
}

pub fn us_core_condition_encounter_diagnosis_search_bundled(
  sp: search_params.UsCoreConditionEncounterDiagnosis,
  client: FhirClient,
) {
  search_params.to_string([
    #("abatement-date", sp.abatement_date),
    #("asserted-date", sp.asserted_date),
    #("category", sp.category),
    #("clinical-status", sp.clinical_status),
    #("code", sp.code),
    #("encounter", sp.encounter),
    #("onset-date", sp.onset_date),
    #("patient", sp.patient),
    #("recorded-date", sp.recorded_date),
    #("_lastUpdated", sp.lastupdated),
  ])
  |> search_any(resources.RtCondition, client)
}

pub fn us_core_condition_encounter_diagnosis_search(
  sp: search_params.UsCoreConditionEncounterDiagnosis,
  client: FhirClient,
) -> Result(List(resources.UsCoreConditionEncounterDiagnosis), Err) {
  case us_core_condition_encounter_diagnosis_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_condition_encounter_diagnosis,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_condition_problems_health_concerns_search_bundled(
  sp: search_params.UsCoreConditionProblemsHealthConcerns,
  client: FhirClient,
) {
  search_params.to_string([
    #("abatement-date", sp.abatement_date),
    #("asserted-date", sp.asserted_date),
    #("category", sp.category),
    #("clinical-status", sp.clinical_status),
    #("code", sp.code),
    #("encounter", sp.encounter),
    #("onset-date", sp.onset_date),
    #("patient", sp.patient),
    #("recorded-date", sp.recorded_date),
    #("_lastUpdated", sp.lastupdated),
  ])
  |> search_any(resources.RtCondition, client)
}

pub fn us_core_condition_problems_health_concerns_search(
  sp: search_params.UsCoreConditionProblemsHealthConcerns,
  client: FhirClient,
) -> Result(List(resources.UsCoreConditionProblemsHealthConcerns), Err) {
  case us_core_condition_problems_health_concerns_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_condition_problems_health_concerns,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_coverage_search_bundled(
  sp: search_params.UsCoreCoverage,
  client: FhirClient,
) {
  search_params.to_string([
    #("patient", sp.patient),
  ])
  |> search_any(resources.RtCoverage, client)
}

pub fn us_core_coverage_search(
  sp: search_params.UsCoreCoverage,
  client: FhirClient,
) -> Result(List(resources.UsCoreCoverage), Err) {
  case us_core_coverage_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_coverage)
    Error(error) -> Error(error)
  }
}

pub fn us_core_diagnosticreport_lab_search_bundled(
  sp: search_params.UsCoreDiagnosticreportLab,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDiagnosticreport, client)
}

pub fn us_core_diagnosticreport_lab_search(
  sp: search_params.UsCoreDiagnosticreportLab,
  client: FhirClient,
) -> Result(List(resources.UsCoreDiagnosticreportLab), Err) {
  case us_core_diagnosticreport_lab_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_diagnosticreport_lab,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_diagnosticreport_note_search_bundled(
  sp: search_params.UsCoreDiagnosticreportNote,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDiagnosticreport, client)
}

pub fn us_core_diagnosticreport_note_search(
  sp: search_params.UsCoreDiagnosticreportNote,
  client: FhirClient,
) -> Result(List(resources.UsCoreDiagnosticreportNote), Err) {
  case us_core_diagnosticreport_note_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_diagnosticreport_note,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_documentreference_search_bundled(
  sp: search_params.UsCoreDocumentreference,
  client: FhirClient,
) {
  search_params.to_string([
    #("_id", sp.id),
    #("category", sp.category),
    #("date", sp.date),
    #("patient", sp.patient),
    #("period", sp.period),
    #("status", sp.status),
    #("type", sp.type_),
  ])
  |> search_any(resources.RtDocumentreference, client)
}

pub fn us_core_documentreference_search(
  sp: search_params.UsCoreDocumentreference,
  client: FhirClient,
) -> Result(List(resources.UsCoreDocumentreference), Err) {
  case us_core_documentreference_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_documentreference,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_encounter_search_bundled(
  sp: search_params.UsCoreEncounter,
  client: FhirClient,
) {
  search_params.to_string([
    #("_id", sp.id),
    #("class", sp.class),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("discharge-disposition", sp.discharge_disposition),
    #("identifier", sp.identifier),
    #("location", sp.location),
    #("patient", sp.patient),
    #("status", sp.status),
    #("type", sp.type_),
  ])
  |> search_any(resources.RtEncounter, client)
}

pub fn us_core_encounter_search(
  sp: search_params.UsCoreEncounter,
  client: FhirClient,
) -> Result(List(resources.UsCoreEncounter), Err) {
  case us_core_encounter_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_encounter)
    Error(error) -> Error(error)
  }
}

pub fn us_core_goal_search_bundled(
  sp: search_params.UsCoreGoal,
  client: FhirClient,
) {
  search_params.to_string([
    #("description", sp.description),
    #("lifecycle-status", sp.lifecycle_status),
    #("patient", sp.patient),
    #("target-date", sp.target_date),
  ])
  |> search_any(resources.RtGoal, client)
}

pub fn us_core_goal_search(
  sp: search_params.UsCoreGoal,
  client: FhirClient,
) -> Result(List(resources.UsCoreGoal), Err) {
  case us_core_goal_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_goal)
    Error(error) -> Error(error)
  }
}

pub fn us_core_head_circumference_search_bundled(
  sp: search_params.UsCoreHeadCircumference,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_head_circumference_search(
  sp: search_params.UsCoreHeadCircumference,
  client: FhirClient,
) -> Result(List(resources.UsCoreHeadCircumference), Err) {
  case us_core_head_circumference_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_head_circumference,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_heart_rate_search_bundled(
  sp: search_params.UsCoreHeartRate,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_heart_rate_search(
  sp: search_params.UsCoreHeartRate,
  client: FhirClient,
) -> Result(List(resources.UsCoreHeartRate), Err) {
  case us_core_heart_rate_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_heart_rate)
    Error(error) -> Error(error)
  }
}

pub fn us_core_immunization_search_bundled(
  sp: search_params.UsCoreImmunization,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtImmunization, client)
}

pub fn us_core_immunization_search(
  sp: search_params.UsCoreImmunization,
  client: FhirClient,
) -> Result(List(resources.UsCoreImmunization), Err) {
  case us_core_immunization_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_immunization)
    Error(error) -> Error(error)
  }
}

pub fn us_core_implantable_device_search_bundled(
  sp: search_params.UsCoreImplantableDevice,
  client: FhirClient,
) {
  search_params.to_string([
    #("patient", sp.patient),
    #("status", sp.status),
    #("type", sp.type_),
  ])
  |> search_any(resources.RtDevice, client)
}

pub fn us_core_implantable_device_search(
  sp: search_params.UsCoreImplantableDevice,
  client: FhirClient,
) -> Result(List(resources.UsCoreImplantableDevice), Err) {
  case us_core_implantable_device_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_implantable_device,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_location_search_bundled(
  sp: search_params.UsCoreLocation,
  client: FhirClient,
) {
  search_params.to_string([
    #("address", sp.address),
    #("address-city", sp.address_city),
    #("address-postalcode", sp.address_postalcode),
    #("address-state", sp.address_state),
    #("name", sp.name),
  ])
  |> search_any(resources.RtLocation, client)
}

pub fn us_core_location_search(
  sp: search_params.UsCoreLocation,
  client: FhirClient,
) -> Result(List(resources.UsCoreLocation), Err) {
  case us_core_location_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_location)
    Error(error) -> Error(error)
  }
}

pub fn us_core_medication_search_bundled(
  _sp: search_params.UsCoreMedication,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtMedication, client)
}

pub fn us_core_medication_search(
  sp: search_params.UsCoreMedication,
  client: FhirClient,
) -> Result(List(resources.UsCoreMedication), Err) {
  case us_core_medication_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_medication)
    Error(error) -> Error(error)
  }
}

pub fn us_core_medicationdispense_search_bundled(
  sp: search_params.UsCoreMedicationdispense,
  client: FhirClient,
) {
  search_params.to_string([
    #("patient", sp.patient),
    #("status", sp.status),
    #("type", sp.type_),
  ])
  |> search_any(resources.RtMedicationdispense, client)
}

pub fn us_core_medicationdispense_search(
  sp: search_params.UsCoreMedicationdispense,
  client: FhirClient,
) -> Result(List(resources.UsCoreMedicationdispense), Err) {
  case us_core_medicationdispense_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_medicationdispense,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_medicationrequest_search_bundled(
  sp: search_params.UsCoreMedicationrequest,
  client: FhirClient,
) {
  search_params.to_string([
    #("authoredon", sp.authoredon),
    #("encounter", sp.encounter),
    #("intent", sp.intent),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicationrequest, client)
}

pub fn us_core_medicationrequest_search(
  sp: search_params.UsCoreMedicationrequest,
  client: FhirClient,
) -> Result(List(resources.UsCoreMedicationrequest), Err) {
  case us_core_medicationrequest_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_medicationrequest,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_observation_clinical_result_search_bundled(
  sp: search_params.UsCoreObservationClinicalResult,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_observation_clinical_result_search(
  sp: search_params.UsCoreObservationClinicalResult,
  client: FhirClient,
) -> Result(List(resources.UsCoreObservationClinicalResult), Err) {
  case us_core_observation_clinical_result_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_clinical_result,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_observation_lab_search_bundled(
  sp: search_params.UsCoreObservationLab,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_observation_lab_search(
  sp: search_params.UsCoreObservationLab,
  client: FhirClient,
) -> Result(List(resources.UsCoreObservationLab), Err) {
  case us_core_observation_lab_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_lab,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_observation_occupation_search_bundled(
  sp: search_params.UsCoreObservationOccupation,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_observation_occupation_search(
  sp: search_params.UsCoreObservationOccupation,
  client: FhirClient,
) -> Result(List(resources.UsCoreObservationOccupation), Err) {
  case us_core_observation_occupation_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_occupation,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_observation_pregnancyintent_search_bundled(
  sp: search_params.UsCoreObservationPregnancyintent,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_observation_pregnancyintent_search(
  sp: search_params.UsCoreObservationPregnancyintent,
  client: FhirClient,
) -> Result(List(resources.UsCoreObservationPregnancyintent), Err) {
  case us_core_observation_pregnancyintent_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_pregnancyintent,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_observation_pregnancystatus_search_bundled(
  sp: search_params.UsCoreObservationPregnancystatus,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_observation_pregnancystatus_search(
  sp: search_params.UsCoreObservationPregnancystatus,
  client: FhirClient,
) -> Result(List(resources.UsCoreObservationPregnancystatus), Err) {
  case us_core_observation_pregnancystatus_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_pregnancystatus,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_observation_screening_assessment_search_bundled(
  sp: search_params.UsCoreObservationScreeningAssessment,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_observation_screening_assessment_search(
  sp: search_params.UsCoreObservationScreeningAssessment,
  client: FhirClient,
) -> Result(List(resources.UsCoreObservationScreeningAssessment), Err) {
  case us_core_observation_screening_assessment_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_screening_assessment,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_observation_sexual_orientation_search_bundled(
  sp: search_params.UsCoreObservationSexualOrientation,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_observation_sexual_orientation_search(
  sp: search_params.UsCoreObservationSexualOrientation,
  client: FhirClient,
) -> Result(List(resources.UsCoreObservationSexualOrientation), Err) {
  case us_core_observation_sexual_orientation_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_sexual_orientation,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_organization_search_bundled(
  sp: search_params.UsCoreOrganization,
  client: FhirClient,
) {
  search_params.to_string([
    #("address", sp.address),
    #("name", sp.name),
  ])
  |> search_any(resources.RtOrganization, client)
}

pub fn us_core_organization_search(
  sp: search_params.UsCoreOrganization,
  client: FhirClient,
) -> Result(List(resources.UsCoreOrganization), Err) {
  case us_core_organization_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_organization)
    Error(error) -> Error(error)
  }
}

pub fn us_core_patient_search_bundled(
  sp: search_params.UsCorePatient,
  client: FhirClient,
) {
  search_params.to_string([
    #("_id", sp.id),
    #("birthdate", sp.birthdate),
    #("death-date", sp.death_date),
    #("family", sp.family),
    #("gender", sp.gender),
    #("given", sp.given),
    #("identifier", sp.identifier),
    #("name", sp.name),
  ])
  |> search_any(resources.RtPatient, client)
}

pub fn us_core_patient_search(
  sp: search_params.UsCorePatient,
  client: FhirClient,
) -> Result(List(resources.UsCorePatient), Err) {
  case us_core_patient_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_patient)
    Error(error) -> Error(error)
  }
}

pub fn us_core_practitioner_search_bundled(
  sp: search_params.UsCorePractitioner,
  client: FhirClient,
) {
  search_params.to_string([
    #("_id", sp.id),
    #("identifier", sp.identifier),
    #("name", sp.name),
  ])
  |> search_any(resources.RtPractitioner, client)
}

pub fn us_core_practitioner_search(
  sp: search_params.UsCorePractitioner,
  client: FhirClient,
) -> Result(List(resources.UsCorePractitioner), Err) {
  case us_core_practitioner_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_practitioner)
    Error(error) -> Error(error)
  }
}

pub fn us_core_practitionerrole_search_bundled(
  sp: search_params.UsCorePractitionerrole,
  client: FhirClient,
) {
  search_params.to_string([
    #("practitioner", sp.practitioner),
    #("specialty", sp.specialty),
  ])
  |> search_any(resources.RtPractitionerrole, client)
}

pub fn us_core_practitionerrole_search(
  sp: search_params.UsCorePractitionerrole,
  client: FhirClient,
) -> Result(List(resources.UsCorePractitionerrole), Err) {
  case us_core_practitionerrole_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_practitionerrole,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_procedure_search_bundled(
  sp: search_params.UsCoreProcedure,
  client: FhirClient,
) {
  search_params.to_string([
    #("code", sp.code),
    #("date", sp.date),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtProcedure, client)
}

pub fn us_core_procedure_search(
  sp: search_params.UsCoreProcedure,
  client: FhirClient,
) -> Result(List(resources.UsCoreProcedure), Err) {
  case us_core_procedure_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_procedure)
    Error(error) -> Error(error)
  }
}

pub fn us_core_provenance_search_bundled(
  _sp: search_params.UsCoreProvenance,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtProvenance, client)
}

pub fn us_core_provenance_search(
  sp: search_params.UsCoreProvenance,
  client: FhirClient,
) -> Result(List(resources.UsCoreProvenance), Err) {
  case us_core_provenance_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_provenance)
    Error(error) -> Error(error)
  }
}

pub fn us_core_pulse_oximetry_search_bundled(
  sp: search_params.UsCorePulseOximetry,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_pulse_oximetry_search(
  sp: search_params.UsCorePulseOximetry,
  client: FhirClient,
) -> Result(List(resources.UsCorePulseOximetry), Err) {
  case us_core_pulse_oximetry_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_pulse_oximetry)
    Error(error) -> Error(error)
  }
}

pub fn us_core_questionnaireresponse_search_bundled(
  sp: search_params.UsCoreQuestionnaireresponse,
  client: FhirClient,
) {
  search_params.to_string([
    #("_id", sp.id),
    #("authored", sp.authored),
    #("patient", sp.patient),
    #("questionnaire", sp.questionnaire),
    #("status", sp.status),
  ])
  |> search_any(resources.RtQuestionnaireresponse, client)
}

pub fn us_core_questionnaireresponse_search(
  sp: search_params.UsCoreQuestionnaireresponse,
  client: FhirClient,
) -> Result(List(resources.UsCoreQuestionnaireresponse), Err) {
  case us_core_questionnaireresponse_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_questionnaireresponse,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_relatedperson_search_bundled(
  sp: search_params.UsCoreRelatedperson,
  client: FhirClient,
) {
  search_params.to_string([
    #("_id", sp.id),
    #("name", sp.name),
    #("patient", sp.patient),
  ])
  |> search_any(resources.RtRelatedperson, client)
}

pub fn us_core_relatedperson_search(
  sp: search_params.UsCoreRelatedperson,
  client: FhirClient,
) -> Result(List(resources.UsCoreRelatedperson), Err) {
  case us_core_relatedperson_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_relatedperson)
    Error(error) -> Error(error)
  }
}

pub fn us_core_respiratory_rate_search_bundled(
  sp: search_params.UsCoreRespiratoryRate,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_respiratory_rate_search(
  sp: search_params.UsCoreRespiratoryRate,
  client: FhirClient,
) -> Result(List(resources.UsCoreRespiratoryRate), Err) {
  case us_core_respiratory_rate_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_respiratory_rate,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_servicerequest_search_bundled(
  sp: search_params.UsCoreServicerequest,
  client: FhirClient,
) {
  search_params.to_string([
    #("_id", sp.id),
    #("authored", sp.authored),
    #("category", sp.category),
    #("code", sp.code),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtServicerequest, client)
}

pub fn us_core_servicerequest_search(
  sp: search_params.UsCoreServicerequest,
  client: FhirClient,
) -> Result(List(resources.UsCoreServicerequest), Err) {
  case us_core_servicerequest_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_servicerequest)
    Error(error) -> Error(error)
  }
}

pub fn us_core_simple_observation_search_bundled(
  sp: search_params.UsCoreSimpleObservation,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_simple_observation_search(
  sp: search_params.UsCoreSimpleObservation,
  client: FhirClient,
) -> Result(List(resources.UsCoreSimpleObservation), Err) {
  case us_core_simple_observation_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_simple_observation,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_smokingstatus_search_bundled(
  sp: search_params.UsCoreSmokingstatus,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_smokingstatus_search(
  sp: search_params.UsCoreSmokingstatus,
  client: FhirClient,
) -> Result(List(resources.UsCoreSmokingstatus), Err) {
  case us_core_smokingstatus_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_smokingstatus)
    Error(error) -> Error(error)
  }
}

pub fn us_core_specimen_search_bundled(
  sp: search_params.UsCoreSpecimen,
  client: FhirClient,
) {
  search_params.to_string([
    #("_id", sp.id),
    #("patient", sp.patient),
  ])
  |> search_any(resources.RtSpecimen, client)
}

pub fn us_core_specimen_search(
  sp: search_params.UsCoreSpecimen,
  client: FhirClient,
) -> Result(List(resources.UsCoreSpecimen), Err) {
  case us_core_specimen_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_specimen)
    Error(error) -> Error(error)
  }
}

pub fn us_core_treatment_intervention_preference_search_bundled(
  sp: search_params.UsCoreTreatmentInterventionPreference,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_treatment_intervention_preference_search(
  sp: search_params.UsCoreTreatmentInterventionPreference,
  client: FhirClient,
) -> Result(List(resources.UsCoreTreatmentInterventionPreference), Err) {
  case us_core_treatment_intervention_preference_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.us_core_treatment_intervention_preference,
      )
    Error(error) -> Error(error)
  }
}

pub fn us_core_vital_signs_search_bundled(
  sp: search_params.UsCoreVitalSigns,
  client: FhirClient,
) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn us_core_vital_signs_search(
  sp: search_params.UsCoreVitalSigns,
  client: FhirClient,
) -> Result(List(resources.UsCoreVitalSigns), Err) {
  case us_core_vital_signs_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_vital_signs)
    Error(error) -> Error(error)
  }
}
