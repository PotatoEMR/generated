////[https://hl7.org/fhir/hl7_fhir_us_core_7_0_0](https://hl7.org/fhir/hl7_fhir_us_core_7_0_0) hl7_fhir_us_core_7_0_0 client using rsvp

import fhir/hl7_fhir_us_core_7_0_0/resources
import fhir/hl7_fhir_us_core_7_0_0/sansio.{type FhirClient}
import fhir/hl7_fhir_us_core_7_0_0/search_params
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect.{type Effect}
import rsvp

pub type Err {
  ErrRsvp(err: rsvp.Error(String))
  ErrSansio(err: sansio.ErrResp)
}

pub fn err_to_string(err: Err) -> String {
  case err {
    ErrRsvp(err:) -> rsvp_err_to_string(err)
    ErrSansio(err:) -> sansio.err_resp_to_string(err)
  }
}

/// When using rsvp, if you attempt update or delete a resource with no id,
/// we do not even send the request or give you an effect to use.
/// Instead of an effect you get just Error(ErrNoId)
pub type ErrNoId {
  ErrNoId
}

fn any_create(
  resource: Json,
  res_type: resources.ResourceType,
  resource_dec: Decoder(r),
  client: FhirClient,
  handle_response: fn(Result(r, Err)) -> a,
) -> Effect(a) {
  let req = sansio.any_create_req(resource, res_type, client)
  sendreq_handleresponse(req, resource_dec, handle_response, client)
}

fn any_read(
  id: String,
  res_type: resources.ResourceType,
  resource_dec: Decoder(r),
  client: FhirClient,
  handle_response: fn(Result(r, Err)) -> a,
) -> Effect(a) {
  let req = sansio.any_read_req(id, res_type, client)
  sendreq_handleresponse(req, resource_dec, handle_response, client)
}

fn any_update(
  id: Option(String),
  resource: Json,
  res_type: resources.ResourceType,
  resource_dec: Decoder(r),
  client: FhirClient,
  handle_response: fn(Result(r, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  let req = sansio.any_update_req(id, resource, res_type, client)
  case req {
    Ok(req) ->
      Ok(sendreq_handleresponse(req, resource_dec, handle_response, client))
    Error(_) -> Error(ErrNoId)
  }
}

pub fn any_delete(
  id: String,
  res_type: resources.ResourceType,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Effect(a) {
  let req = sansio.any_delete_req(id, res_type, client)
  case client.print_sent_requests {
    sansio.LoggingOn -> req |> sansio.req_to_string |> io.println
    sansio.LoggingOff -> Nil
  }
  let handle_read = fn(resp_res: Result(Response(String), rsvp.Error(String))) {
    case client.print_received_responses {
      sansio.LoggingOn ->
        case resp_res {
          Ok(resp) -> resp |> sansio.resp_to_string
          Error(err) -> err |> rsvp_err_to_string
        }
        |> io.println
      sansio.LoggingOff -> Nil
    }
    handle_response(case resp_res {
      Error(err) -> Error(ErrRsvp(err))
      Ok(resp) ->
        case sansio.delete_response(resp) {
          Ok(oo_or_http) -> Ok(oo_or_http)
          Error(err) -> Error(ErrSansio(err))
        }
    })
  }
  let handler = rsvp.expect_any_response(handle_read)
  req
  |> request.set_body(case req.body {
    None -> ""
    Some(body) -> json.to_string(body)
  })
  |> rsvp.send(handler)
}

/// write out search string manually, in case typed search params don't work
pub fn search_any(
  search_string: String,
  res_type: resources.ResourceType,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  let req = sansio.any_search_req(search_string, res_type, client)
  sendreq_handleresponse(
    req,
    resources.bundle_decoder(),
    handle_response,
    client,
  )
}

/// instead of failing whole decoder on bundle entry with invalid resource,
/// return valid resources alongside list of errors
pub fn search_any_forgiving(
  search_string: String,
  res_type: resources.ResourceType,
  client: FhirClient,
  handle_response: fn(Result(resources.BundleForgiving, Err)) -> msg,
) -> Effect(msg) {
  let req = sansio.any_search_req(search_string, res_type, client)
  sendreq_handleresponse(
    req,
    resources.bundle_decoder_forgiving(),
    handle_response,
    client,
  )
}

// run any operation string on any resource string, optionally using Parameters
pub fn operation_any(
  params params: Option(resources.Parameters),
  operation_name operation_name: String,
  res_type res_type: resources.ResourceType,
  res_id res_id: Option(String),
  res_decoder res_decoder: Decoder(res),
  client client: FhirClient,
  handle_response handle_response: fn(Result(res, Err)) -> msg,
) -> Effect(msg) {
  let req =
    sansio.any_operation_req(res_type, res_id, operation_name, params, client)
  sendreq_handleresponse(req, res_decoder, handle_response, client)
}

pub fn batch(
  reqs: List(Request(Option(Json))),
  bundle_type: sansio.PostBundleType,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  let req = sansio.batch_req(reqs, bundle_type, client)
  sendreq_handleresponse(
    req,
    resources.bundle_decoder(),
    handle_response,
    client,
  )
}

fn sendreq_handleresponse(
  req: Request(Option(Json)),
  res_dec: Decoder(r),
  handle_response: fn(Result(r, Err)) -> a,
  client: FhirClient,
) -> Effect(a) {
  sendreq_handleresponse_andprocess(
    req,
    res_dec,
    handle_response,
    fn(a) { a },
    client,
  )
}

fn sendreq_handleresponse_andprocess(
  req: Request(Option(Json)),
  res_dec: Decoder(r),
  handle_response: fn(Result(b, Err)) -> a,
  process_res: fn(r) -> b,
  client: FhirClient,
) -> Effect(a) {
  case client.print_sent_requests {
    sansio.LoggingOn -> req |> sansio.req_to_string |> io.println
    sansio.LoggingOff -> Nil
  }
  let handle_read = fn(resp_res: Result(Response(String), rsvp.Error(String))) {
    case client.print_received_responses {
      sansio.LoggingOn ->
        case resp_res {
          Ok(resp) -> resp |> sansio.resp_to_string
          Error(err) -> err |> rsvp_err_to_string
        }
        |> io.println
      sansio.LoggingOff -> Nil
    }
    handle_response(case resp_res {
      Error(err) -> Error(ErrRsvp(err))
      Ok(resp_res) -> {
        case sansio.any_response(resp_res, res_dec) {
          Ok(res) -> Ok(process_res(res))
          Error(err) -> Error(ErrSansio(err))
        }
      }
    })
  }
  let handler = rsvp.expect_any_response(handle_read)
  req
  |> request.set_body(case req.body {
    None -> ""
    Some(body) -> json.to_string(body)
  })
  |> rsvp.send(handler)
}

fn rsvp_err_to_string(err: rsvp.Error(String)) -> String {
  case err {
    rsvp.BadBody -> "invalid http response body"
    rsvp.BadUrl(url) -> "invalid url: " <> url
    rsvp.HttpError(resp) -> "resp not 2xx: " <> sansio.resp_to_string(resp)
    rsvp.JsonError(err) ->
      "err decoding json: "
      <> case err {
        json.UnexpectedEndOfInput -> "unexpected end of input"
        json.UnexpectedByte(err) -> "unexpected byte: " <> err
        json.UnexpectedSequence(err) -> "unexpected sequence " <> err
        json.UnableToDecode(errors) ->
          "unable to decode: "
          <> list.map(errors, fn(error) {
            "expected "
            <> error.expected
            <> " but found "
            <> error.found
            <> " at "
            <> string.join(error.path, "/")
          })
          |> string.join("\n")
      }
    rsvp.NetworkError ->
      "network error, http request could not connect to server"
    rsvp.UnhandledResponse(resp) ->
      "rsvp handler does not know how to handle response: "
      <> sansio.resp_to_string(resp)
  }
}

pub fn bundle_create(
  resource: resources.Bundle,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.bundle_to_json(resource),
    resources.RtBundle,
    resources.bundle_decoder(),
    client,
    handle_response,
  )
}

pub fn bundle_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtBundle,
    resources.bundle_decoder(),
    client,
    handle_response,
  )
}

pub fn bundle_update(
  resource: resources.Bundle,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.bundle_to_json(resource),
    resources.RtBundle,
    resources.bundle_decoder(),
    client,
    handle_response,
  )
}

pub fn bundle_delete(
  resource: resources.Bundle,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtBundle, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn endpoint_create(
  resource: resources.Endpoint,
  client: FhirClient,
  handle_response: fn(Result(resources.Endpoint, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.endpoint_to_json(resource),
    resources.RtEndpoint,
    resources.endpoint_decoder(),
    client,
    handle_response,
  )
}

pub fn endpoint_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Endpoint, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtEndpoint,
    resources.endpoint_decoder(),
    client,
    handle_response,
  )
}

pub fn endpoint_update(
  resource: resources.Endpoint,
  client: FhirClient,
  handle_response: fn(Result(resources.Endpoint, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.endpoint_to_json(resource),
    resources.RtEndpoint,
    resources.endpoint_decoder(),
    client,
    handle_response,
  )
}

pub fn endpoint_delete(
  resource: resources.Endpoint,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtEndpoint, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn operationoutcome_create(
  resource: resources.Operationoutcome,
  client: FhirClient,
  handle_response: fn(Result(resources.Operationoutcome, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.operationoutcome_to_json(resource),
    resources.RtOperationoutcome,
    resources.operationoutcome_decoder(),
    client,
    handle_response,
  )
}

pub fn operationoutcome_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.Operationoutcome, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtOperationoutcome,
    resources.operationoutcome_decoder(),
    client,
    handle_response,
  )
}

pub fn operationoutcome_update(
  resource: resources.Operationoutcome,
  client: FhirClient,
  handle_response: fn(Result(resources.Operationoutcome, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.operationoutcome_to_json(resource),
    resources.RtOperationoutcome,
    resources.operationoutcome_decoder(),
    client,
    handle_response,
  )
}

pub fn operationoutcome_delete(
  resource: resources.Operationoutcome,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtOperationoutcome, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn head_occipital_frontal_circumference_percentile_create(
  resource: resources.HeadOccipitalFrontalCircumferencePercentile,
  client: FhirClient,
  handle_response: fn(
    Result(resources.HeadOccipitalFrontalCircumferencePercentile, Err),
  ) -> a,
) -> Effect(a) {
  any_create(
    resources.head_occipital_frontal_circumference_percentile_to_json(resource),
    resources.RtObservation,
    resources.head_occipital_frontal_circumference_percentile_decoder(),
    client,
    handle_response,
  )
}

pub fn head_occipital_frontal_circumference_percentile_read(
  id: String,
  client: FhirClient,
  handle_response: fn(
    Result(resources.HeadOccipitalFrontalCircumferencePercentile, Err),
  ) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.head_occipital_frontal_circumference_percentile_decoder(),
    client,
    handle_response,
  )
}

pub fn head_occipital_frontal_circumference_percentile_update(
  resource: resources.HeadOccipitalFrontalCircumferencePercentile,
  client: FhirClient,
  handle_response: fn(
    Result(resources.HeadOccipitalFrontalCircumferencePercentile, Err),
  ) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.head_occipital_frontal_circumference_percentile_to_json(resource),
    resources.RtObservation,
    resources.head_occipital_frontal_circumference_percentile_decoder(),
    client,
    handle_response,
  )
}

pub fn head_occipital_frontal_circumference_percentile_delete(
  resource: resources.HeadOccipitalFrontalCircumferencePercentile,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn pediatric_bmi_for_age_create(
  resource: resources.PediatricBmiForAge,
  client: FhirClient,
  handle_response: fn(Result(resources.PediatricBmiForAge, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.pediatric_bmi_for_age_to_json(resource),
    resources.RtObservation,
    resources.pediatric_bmi_for_age_decoder(),
    client,
    handle_response,
  )
}

pub fn pediatric_bmi_for_age_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.PediatricBmiForAge, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.pediatric_bmi_for_age_decoder(),
    client,
    handle_response,
  )
}

pub fn pediatric_bmi_for_age_update(
  resource: resources.PediatricBmiForAge,
  client: FhirClient,
  handle_response: fn(Result(resources.PediatricBmiForAge, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.pediatric_bmi_for_age_to_json(resource),
    resources.RtObservation,
    resources.pediatric_bmi_for_age_decoder(),
    client,
    handle_response,
  )
}

pub fn pediatric_bmi_for_age_delete(
  resource: resources.PediatricBmiForAge,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn pediatric_weight_for_height_create(
  resource: resources.PediatricWeightForHeight,
  client: FhirClient,
  handle_response: fn(Result(resources.PediatricWeightForHeight, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.pediatric_weight_for_height_to_json(resource),
    resources.RtObservation,
    resources.pediatric_weight_for_height_decoder(),
    client,
    handle_response,
  )
}

pub fn pediatric_weight_for_height_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.PediatricWeightForHeight, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.pediatric_weight_for_height_decoder(),
    client,
    handle_response,
  )
}

pub fn pediatric_weight_for_height_update(
  resource: resources.PediatricWeightForHeight,
  client: FhirClient,
  handle_response: fn(Result(resources.PediatricWeightForHeight, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.pediatric_weight_for_height_to_json(resource),
    resources.RtObservation,
    resources.pediatric_weight_for_height_decoder(),
    client,
    handle_response,
  )
}

pub fn pediatric_weight_for_height_delete(
  resource: resources.PediatricWeightForHeight,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_allergyintolerance_create(
  resource: resources.UsCoreAllergyintolerance,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreAllergyintolerance, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_allergyintolerance_to_json(resource),
    resources.RtAllergyintolerance,
    resources.us_core_allergyintolerance_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_allergyintolerance_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreAllergyintolerance, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtAllergyintolerance,
    resources.us_core_allergyintolerance_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_allergyintolerance_update(
  resource: resources.UsCoreAllergyintolerance,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreAllergyintolerance, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_allergyintolerance_to_json(resource),
    resources.RtAllergyintolerance,
    resources.us_core_allergyintolerance_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_allergyintolerance_delete(
  resource: resources.UsCoreAllergyintolerance,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtAllergyintolerance, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_average_blood_pressure_create(
  resource: resources.UsCoreAverageBloodPressure,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreAverageBloodPressure, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_average_blood_pressure_to_json(resource),
    resources.RtObservation,
    resources.us_core_average_blood_pressure_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_average_blood_pressure_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreAverageBloodPressure, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_average_blood_pressure_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_average_blood_pressure_update(
  resource: resources.UsCoreAverageBloodPressure,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreAverageBloodPressure, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_average_blood_pressure_to_json(resource),
    resources.RtObservation,
    resources.us_core_average_blood_pressure_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_average_blood_pressure_delete(
  resource: resources.UsCoreAverageBloodPressure,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_blood_pressure_create(
  resource: resources.UsCoreBloodPressure,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBloodPressure, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_blood_pressure_to_json(resource),
    resources.RtObservation,
    resources.us_core_blood_pressure_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_blood_pressure_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBloodPressure, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_blood_pressure_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_blood_pressure_update(
  resource: resources.UsCoreBloodPressure,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBloodPressure, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_blood_pressure_to_json(resource),
    resources.RtObservation,
    resources.us_core_blood_pressure_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_blood_pressure_delete(
  resource: resources.UsCoreBloodPressure,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_bmi_create(
  resource: resources.UsCoreBmi,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBmi, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_bmi_to_json(resource),
    resources.RtObservation,
    resources.us_core_bmi_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_bmi_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBmi, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_bmi_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_bmi_update(
  resource: resources.UsCoreBmi,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBmi, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_bmi_to_json(resource),
    resources.RtObservation,
    resources.us_core_bmi_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_bmi_delete(
  resource: resources.UsCoreBmi,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_body_height_create(
  resource: resources.UsCoreBodyHeight,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBodyHeight, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_body_height_to_json(resource),
    resources.RtObservation,
    resources.us_core_body_height_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_body_height_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBodyHeight, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_body_height_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_body_height_update(
  resource: resources.UsCoreBodyHeight,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBodyHeight, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_body_height_to_json(resource),
    resources.RtObservation,
    resources.us_core_body_height_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_body_height_delete(
  resource: resources.UsCoreBodyHeight,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_body_temperature_create(
  resource: resources.UsCoreBodyTemperature,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBodyTemperature, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_body_temperature_to_json(resource),
    resources.RtObservation,
    resources.us_core_body_temperature_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_body_temperature_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBodyTemperature, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_body_temperature_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_body_temperature_update(
  resource: resources.UsCoreBodyTemperature,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBodyTemperature, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_body_temperature_to_json(resource),
    resources.RtObservation,
    resources.us_core_body_temperature_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_body_temperature_delete(
  resource: resources.UsCoreBodyTemperature,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_body_weight_create(
  resource: resources.UsCoreBodyWeight,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBodyWeight, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_body_weight_to_json(resource),
    resources.RtObservation,
    resources.us_core_body_weight_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_body_weight_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBodyWeight, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_body_weight_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_body_weight_update(
  resource: resources.UsCoreBodyWeight,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreBodyWeight, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_body_weight_to_json(resource),
    resources.RtObservation,
    resources.us_core_body_weight_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_body_weight_delete(
  resource: resources.UsCoreBodyWeight,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_care_experience_preference_create(
  resource: resources.UsCoreCareExperiencePreference,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreCareExperiencePreference, Err)) ->
    a,
) -> Effect(a) {
  any_create(
    resources.us_core_care_experience_preference_to_json(resource),
    resources.RtObservation,
    resources.us_core_care_experience_preference_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_care_experience_preference_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreCareExperiencePreference, Err)) ->
    a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_care_experience_preference_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_care_experience_preference_update(
  resource: resources.UsCoreCareExperiencePreference,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreCareExperiencePreference, Err)) ->
    a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_care_experience_preference_to_json(resource),
    resources.RtObservation,
    resources.us_core_care_experience_preference_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_care_experience_preference_delete(
  resource: resources.UsCoreCareExperiencePreference,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_careplan_create(
  resource: resources.UsCoreCareplan,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreCareplan, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_careplan_to_json(resource),
    resources.RtCareplan,
    resources.us_core_careplan_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_careplan_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreCareplan, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCareplan,
    resources.us_core_careplan_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_careplan_update(
  resource: resources.UsCoreCareplan,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreCareplan, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_careplan_to_json(resource),
    resources.RtCareplan,
    resources.us_core_careplan_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_careplan_delete(
  resource: resources.UsCoreCareplan,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtCareplan, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_careteam_create(
  resource: resources.UsCoreCareteam,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreCareteam, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_careteam_to_json(resource),
    resources.RtCareteam,
    resources.us_core_careteam_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_careteam_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreCareteam, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCareteam,
    resources.us_core_careteam_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_careteam_update(
  resource: resources.UsCoreCareteam,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreCareteam, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_careteam_to_json(resource),
    resources.RtCareteam,
    resources.us_core_careteam_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_careteam_delete(
  resource: resources.UsCoreCareteam,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtCareteam, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_condition_encounter_diagnosis_create(
  resource: resources.UsCoreConditionEncounterDiagnosis,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreConditionEncounterDiagnosis, Err)) ->
    a,
) -> Effect(a) {
  any_create(
    resources.us_core_condition_encounter_diagnosis_to_json(resource),
    resources.RtCondition,
    resources.us_core_condition_encounter_diagnosis_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_condition_encounter_diagnosis_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreConditionEncounterDiagnosis, Err)) ->
    a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCondition,
    resources.us_core_condition_encounter_diagnosis_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_condition_encounter_diagnosis_update(
  resource: resources.UsCoreConditionEncounterDiagnosis,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreConditionEncounterDiagnosis, Err)) ->
    a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_condition_encounter_diagnosis_to_json(resource),
    resources.RtCondition,
    resources.us_core_condition_encounter_diagnosis_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_condition_encounter_diagnosis_delete(
  resource: resources.UsCoreConditionEncounterDiagnosis,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtCondition, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_condition_problems_health_concerns_create(
  resource: resources.UsCoreConditionProblemsHealthConcerns,
  client: FhirClient,
  handle_response: fn(
    Result(resources.UsCoreConditionProblemsHealthConcerns, Err),
  ) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_condition_problems_health_concerns_to_json(resource),
    resources.RtCondition,
    resources.us_core_condition_problems_health_concerns_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_condition_problems_health_concerns_read(
  id: String,
  client: FhirClient,
  handle_response: fn(
    Result(resources.UsCoreConditionProblemsHealthConcerns, Err),
  ) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCondition,
    resources.us_core_condition_problems_health_concerns_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_condition_problems_health_concerns_update(
  resource: resources.UsCoreConditionProblemsHealthConcerns,
  client: FhirClient,
  handle_response: fn(
    Result(resources.UsCoreConditionProblemsHealthConcerns, Err),
  ) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_condition_problems_health_concerns_to_json(resource),
    resources.RtCondition,
    resources.us_core_condition_problems_health_concerns_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_condition_problems_health_concerns_delete(
  resource: resources.UsCoreConditionProblemsHealthConcerns,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtCondition, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_coverage_create(
  resource: resources.UsCoreCoverage,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreCoverage, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_coverage_to_json(resource),
    resources.RtCoverage,
    resources.us_core_coverage_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_coverage_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreCoverage, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtCoverage,
    resources.us_core_coverage_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_coverage_update(
  resource: resources.UsCoreCoverage,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreCoverage, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_coverage_to_json(resource),
    resources.RtCoverage,
    resources.us_core_coverage_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_coverage_delete(
  resource: resources.UsCoreCoverage,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtCoverage, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_diagnosticreport_lab_create(
  resource: resources.UsCoreDiagnosticreportLab,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreDiagnosticreportLab, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_diagnosticreport_lab_to_json(resource),
    resources.RtDiagnosticreport,
    resources.us_core_diagnosticreport_lab_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_diagnosticreport_lab_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreDiagnosticreportLab, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDiagnosticreport,
    resources.us_core_diagnosticreport_lab_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_diagnosticreport_lab_update(
  resource: resources.UsCoreDiagnosticreportLab,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreDiagnosticreportLab, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_diagnosticreport_lab_to_json(resource),
    resources.RtDiagnosticreport,
    resources.us_core_diagnosticreport_lab_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_diagnosticreport_lab_delete(
  resource: resources.UsCoreDiagnosticreportLab,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtDiagnosticreport, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_diagnosticreport_note_create(
  resource: resources.UsCoreDiagnosticreportNote,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreDiagnosticreportNote, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_diagnosticreport_note_to_json(resource),
    resources.RtDiagnosticreport,
    resources.us_core_diagnosticreport_note_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_diagnosticreport_note_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreDiagnosticreportNote, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDiagnosticreport,
    resources.us_core_diagnosticreport_note_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_diagnosticreport_note_update(
  resource: resources.UsCoreDiagnosticreportNote,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreDiagnosticreportNote, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_diagnosticreport_note_to_json(resource),
    resources.RtDiagnosticreport,
    resources.us_core_diagnosticreport_note_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_diagnosticreport_note_delete(
  resource: resources.UsCoreDiagnosticreportNote,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtDiagnosticreport, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_documentreference_create(
  resource: resources.UsCoreDocumentreference,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreDocumentreference, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_documentreference_to_json(resource),
    resources.RtDocumentreference,
    resources.us_core_documentreference_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_documentreference_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreDocumentreference, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDocumentreference,
    resources.us_core_documentreference_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_documentreference_update(
  resource: resources.UsCoreDocumentreference,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreDocumentreference, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_documentreference_to_json(resource),
    resources.RtDocumentreference,
    resources.us_core_documentreference_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_documentreference_delete(
  resource: resources.UsCoreDocumentreference,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtDocumentreference, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_encounter_create(
  resource: resources.UsCoreEncounter,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreEncounter, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_encounter_to_json(resource),
    resources.RtEncounter,
    resources.us_core_encounter_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_encounter_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreEncounter, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtEncounter,
    resources.us_core_encounter_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_encounter_update(
  resource: resources.UsCoreEncounter,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreEncounter, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_encounter_to_json(resource),
    resources.RtEncounter,
    resources.us_core_encounter_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_encounter_delete(
  resource: resources.UsCoreEncounter,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtEncounter, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_goal_create(
  resource: resources.UsCoreGoal,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreGoal, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_goal_to_json(resource),
    resources.RtGoal,
    resources.us_core_goal_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_goal_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreGoal, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtGoal,
    resources.us_core_goal_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_goal_update(
  resource: resources.UsCoreGoal,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreGoal, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_goal_to_json(resource),
    resources.RtGoal,
    resources.us_core_goal_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_goal_delete(
  resource: resources.UsCoreGoal,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtGoal, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_head_circumference_create(
  resource: resources.UsCoreHeadCircumference,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreHeadCircumference, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_head_circumference_to_json(resource),
    resources.RtObservation,
    resources.us_core_head_circumference_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_head_circumference_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreHeadCircumference, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_head_circumference_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_head_circumference_update(
  resource: resources.UsCoreHeadCircumference,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreHeadCircumference, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_head_circumference_to_json(resource),
    resources.RtObservation,
    resources.us_core_head_circumference_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_head_circumference_delete(
  resource: resources.UsCoreHeadCircumference,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_heart_rate_create(
  resource: resources.UsCoreHeartRate,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreHeartRate, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_heart_rate_to_json(resource),
    resources.RtObservation,
    resources.us_core_heart_rate_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_heart_rate_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreHeartRate, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_heart_rate_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_heart_rate_update(
  resource: resources.UsCoreHeartRate,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreHeartRate, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_heart_rate_to_json(resource),
    resources.RtObservation,
    resources.us_core_heart_rate_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_heart_rate_delete(
  resource: resources.UsCoreHeartRate,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_immunization_create(
  resource: resources.UsCoreImmunization,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreImmunization, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_immunization_to_json(resource),
    resources.RtImmunization,
    resources.us_core_immunization_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_immunization_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreImmunization, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtImmunization,
    resources.us_core_immunization_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_immunization_update(
  resource: resources.UsCoreImmunization,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreImmunization, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_immunization_to_json(resource),
    resources.RtImmunization,
    resources.us_core_immunization_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_immunization_delete(
  resource: resources.UsCoreImmunization,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtImmunization, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_implantable_device_create(
  resource: resources.UsCoreImplantableDevice,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreImplantableDevice, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_implantable_device_to_json(resource),
    resources.RtDevice,
    resources.us_core_implantable_device_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_implantable_device_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreImplantableDevice, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtDevice,
    resources.us_core_implantable_device_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_implantable_device_update(
  resource: resources.UsCoreImplantableDevice,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreImplantableDevice, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_implantable_device_to_json(resource),
    resources.RtDevice,
    resources.us_core_implantable_device_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_implantable_device_delete(
  resource: resources.UsCoreImplantableDevice,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtDevice, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_location_create(
  resource: resources.UsCoreLocation,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreLocation, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_location_to_json(resource),
    resources.RtLocation,
    resources.us_core_location_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_location_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreLocation, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtLocation,
    resources.us_core_location_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_location_update(
  resource: resources.UsCoreLocation,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreLocation, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_location_to_json(resource),
    resources.RtLocation,
    resources.us_core_location_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_location_delete(
  resource: resources.UsCoreLocation,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtLocation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_medication_create(
  resource: resources.UsCoreMedication,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreMedication, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_medication_to_json(resource),
    resources.RtMedication,
    resources.us_core_medication_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_medication_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreMedication, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMedication,
    resources.us_core_medication_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_medication_update(
  resource: resources.UsCoreMedication,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreMedication, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_medication_to_json(resource),
    resources.RtMedication,
    resources.us_core_medication_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_medication_delete(
  resource: resources.UsCoreMedication,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtMedication, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_medicationdispense_create(
  resource: resources.UsCoreMedicationdispense,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreMedicationdispense, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_medicationdispense_to_json(resource),
    resources.RtMedicationdispense,
    resources.us_core_medicationdispense_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_medicationdispense_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreMedicationdispense, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMedicationdispense,
    resources.us_core_medicationdispense_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_medicationdispense_update(
  resource: resources.UsCoreMedicationdispense,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreMedicationdispense, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_medicationdispense_to_json(resource),
    resources.RtMedicationdispense,
    resources.us_core_medicationdispense_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_medicationdispense_delete(
  resource: resources.UsCoreMedicationdispense,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtMedicationdispense, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_medicationrequest_create(
  resource: resources.UsCoreMedicationrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreMedicationrequest, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_medicationrequest_to_json(resource),
    resources.RtMedicationrequest,
    resources.us_core_medicationrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_medicationrequest_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreMedicationrequest, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtMedicationrequest,
    resources.us_core_medicationrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_medicationrequest_update(
  resource: resources.UsCoreMedicationrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreMedicationrequest, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_medicationrequest_to_json(resource),
    resources.RtMedicationrequest,
    resources.us_core_medicationrequest_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_medicationrequest_delete(
  resource: resources.UsCoreMedicationrequest,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtMedicationrequest, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_observation_clinical_result_create(
  resource: resources.UsCoreObservationClinicalResult,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationClinicalResult, Err)) ->
    a,
) -> Effect(a) {
  any_create(
    resources.us_core_observation_clinical_result_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_clinical_result_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_clinical_result_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationClinicalResult, Err)) ->
    a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_observation_clinical_result_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_clinical_result_update(
  resource: resources.UsCoreObservationClinicalResult,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationClinicalResult, Err)) ->
    a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_observation_clinical_result_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_clinical_result_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_clinical_result_delete(
  resource: resources.UsCoreObservationClinicalResult,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_observation_lab_create(
  resource: resources.UsCoreObservationLab,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationLab, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_observation_lab_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_lab_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_lab_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationLab, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_observation_lab_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_lab_update(
  resource: resources.UsCoreObservationLab,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationLab, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_observation_lab_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_lab_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_lab_delete(
  resource: resources.UsCoreObservationLab,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_observation_occupation_create(
  resource: resources.UsCoreObservationOccupation,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationOccupation, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_observation_occupation_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_occupation_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_occupation_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationOccupation, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_observation_occupation_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_occupation_update(
  resource: resources.UsCoreObservationOccupation,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationOccupation, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_observation_occupation_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_occupation_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_occupation_delete(
  resource: resources.UsCoreObservationOccupation,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_observation_pregnancyintent_create(
  resource: resources.UsCoreObservationPregnancyintent,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationPregnancyintent, Err)) ->
    a,
) -> Effect(a) {
  any_create(
    resources.us_core_observation_pregnancyintent_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_pregnancyintent_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_pregnancyintent_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationPregnancyintent, Err)) ->
    a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_observation_pregnancyintent_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_pregnancyintent_update(
  resource: resources.UsCoreObservationPregnancyintent,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationPregnancyintent, Err)) ->
    a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_observation_pregnancyintent_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_pregnancyintent_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_pregnancyintent_delete(
  resource: resources.UsCoreObservationPregnancyintent,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_observation_pregnancystatus_create(
  resource: resources.UsCoreObservationPregnancystatus,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationPregnancystatus, Err)) ->
    a,
) -> Effect(a) {
  any_create(
    resources.us_core_observation_pregnancystatus_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_pregnancystatus_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_pregnancystatus_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationPregnancystatus, Err)) ->
    a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_observation_pregnancystatus_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_pregnancystatus_update(
  resource: resources.UsCoreObservationPregnancystatus,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationPregnancystatus, Err)) ->
    a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_observation_pregnancystatus_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_pregnancystatus_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_pregnancystatus_delete(
  resource: resources.UsCoreObservationPregnancystatus,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_observation_screening_assessment_create(
  resource: resources.UsCoreObservationScreeningAssessment,
  client: FhirClient,
  handle_response: fn(
    Result(resources.UsCoreObservationScreeningAssessment, Err),
  ) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_observation_screening_assessment_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_screening_assessment_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_screening_assessment_read(
  id: String,
  client: FhirClient,
  handle_response: fn(
    Result(resources.UsCoreObservationScreeningAssessment, Err),
  ) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_observation_screening_assessment_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_screening_assessment_update(
  resource: resources.UsCoreObservationScreeningAssessment,
  client: FhirClient,
  handle_response: fn(
    Result(resources.UsCoreObservationScreeningAssessment, Err),
  ) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_observation_screening_assessment_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_screening_assessment_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_screening_assessment_delete(
  resource: resources.UsCoreObservationScreeningAssessment,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_observation_sexual_orientation_create(
  resource: resources.UsCoreObservationSexualOrientation,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationSexualOrientation, Err)) ->
    a,
) -> Effect(a) {
  any_create(
    resources.us_core_observation_sexual_orientation_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_sexual_orientation_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_sexual_orientation_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationSexualOrientation, Err)) ->
    a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_observation_sexual_orientation_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_sexual_orientation_update(
  resource: resources.UsCoreObservationSexualOrientation,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreObservationSexualOrientation, Err)) ->
    a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_observation_sexual_orientation_to_json(resource),
    resources.RtObservation,
    resources.us_core_observation_sexual_orientation_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_observation_sexual_orientation_delete(
  resource: resources.UsCoreObservationSexualOrientation,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_organization_create(
  resource: resources.UsCoreOrganization,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreOrganization, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_organization_to_json(resource),
    resources.RtOrganization,
    resources.us_core_organization_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_organization_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreOrganization, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtOrganization,
    resources.us_core_organization_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_organization_update(
  resource: resources.UsCoreOrganization,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreOrganization, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_organization_to_json(resource),
    resources.RtOrganization,
    resources.us_core_organization_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_organization_delete(
  resource: resources.UsCoreOrganization,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtOrganization, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_patient_create(
  resource: resources.UsCorePatient,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCorePatient, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_patient_to_json(resource),
    resources.RtPatient,
    resources.us_core_patient_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_patient_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCorePatient, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtPatient,
    resources.us_core_patient_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_patient_update(
  resource: resources.UsCorePatient,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCorePatient, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_patient_to_json(resource),
    resources.RtPatient,
    resources.us_core_patient_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_patient_delete(
  resource: resources.UsCorePatient,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) -> Ok(any_delete(id, resources.RtPatient, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_practitioner_create(
  resource: resources.UsCorePractitioner,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCorePractitioner, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_practitioner_to_json(resource),
    resources.RtPractitioner,
    resources.us_core_practitioner_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_practitioner_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCorePractitioner, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtPractitioner,
    resources.us_core_practitioner_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_practitioner_update(
  resource: resources.UsCorePractitioner,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCorePractitioner, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_practitioner_to_json(resource),
    resources.RtPractitioner,
    resources.us_core_practitioner_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_practitioner_delete(
  resource: resources.UsCorePractitioner,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtPractitioner, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_practitionerrole_create(
  resource: resources.UsCorePractitionerrole,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCorePractitionerrole, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_practitionerrole_to_json(resource),
    resources.RtPractitionerrole,
    resources.us_core_practitionerrole_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_practitionerrole_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCorePractitionerrole, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtPractitionerrole,
    resources.us_core_practitionerrole_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_practitionerrole_update(
  resource: resources.UsCorePractitionerrole,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCorePractitionerrole, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_practitionerrole_to_json(resource),
    resources.RtPractitionerrole,
    resources.us_core_practitionerrole_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_practitionerrole_delete(
  resource: resources.UsCorePractitionerrole,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtPractitionerrole, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_procedure_create(
  resource: resources.UsCoreProcedure,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreProcedure, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_procedure_to_json(resource),
    resources.RtProcedure,
    resources.us_core_procedure_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_procedure_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreProcedure, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtProcedure,
    resources.us_core_procedure_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_procedure_update(
  resource: resources.UsCoreProcedure,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreProcedure, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_procedure_to_json(resource),
    resources.RtProcedure,
    resources.us_core_procedure_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_procedure_delete(
  resource: resources.UsCoreProcedure,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtProcedure, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_provenance_create(
  resource: resources.UsCoreProvenance,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreProvenance, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_provenance_to_json(resource),
    resources.RtProvenance,
    resources.us_core_provenance_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_provenance_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreProvenance, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtProvenance,
    resources.us_core_provenance_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_provenance_update(
  resource: resources.UsCoreProvenance,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreProvenance, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_provenance_to_json(resource),
    resources.RtProvenance,
    resources.us_core_provenance_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_provenance_delete(
  resource: resources.UsCoreProvenance,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtProvenance, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_pulse_oximetry_create(
  resource: resources.UsCorePulseOximetry,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCorePulseOximetry, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_pulse_oximetry_to_json(resource),
    resources.RtObservation,
    resources.us_core_pulse_oximetry_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_pulse_oximetry_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCorePulseOximetry, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_pulse_oximetry_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_pulse_oximetry_update(
  resource: resources.UsCorePulseOximetry,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCorePulseOximetry, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_pulse_oximetry_to_json(resource),
    resources.RtObservation,
    resources.us_core_pulse_oximetry_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_pulse_oximetry_delete(
  resource: resources.UsCorePulseOximetry,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_questionnaireresponse_create(
  resource: resources.UsCoreQuestionnaireresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreQuestionnaireresponse, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_questionnaireresponse_to_json(resource),
    resources.RtQuestionnaireresponse,
    resources.us_core_questionnaireresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_questionnaireresponse_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreQuestionnaireresponse, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtQuestionnaireresponse,
    resources.us_core_questionnaireresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_questionnaireresponse_update(
  resource: resources.UsCoreQuestionnaireresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreQuestionnaireresponse, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_questionnaireresponse_to_json(resource),
    resources.RtQuestionnaireresponse,
    resources.us_core_questionnaireresponse_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_questionnaireresponse_delete(
  resource: resources.UsCoreQuestionnaireresponse,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(
        id,
        resources.RtQuestionnaireresponse,
        client,
        handle_response,
      ))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_relatedperson_create(
  resource: resources.UsCoreRelatedperson,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreRelatedperson, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_relatedperson_to_json(resource),
    resources.RtRelatedperson,
    resources.us_core_relatedperson_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_relatedperson_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreRelatedperson, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtRelatedperson,
    resources.us_core_relatedperson_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_relatedperson_update(
  resource: resources.UsCoreRelatedperson,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreRelatedperson, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_relatedperson_to_json(resource),
    resources.RtRelatedperson,
    resources.us_core_relatedperson_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_relatedperson_delete(
  resource: resources.UsCoreRelatedperson,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtRelatedperson, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_respiratory_rate_create(
  resource: resources.UsCoreRespiratoryRate,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreRespiratoryRate, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_respiratory_rate_to_json(resource),
    resources.RtObservation,
    resources.us_core_respiratory_rate_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_respiratory_rate_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreRespiratoryRate, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_respiratory_rate_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_respiratory_rate_update(
  resource: resources.UsCoreRespiratoryRate,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreRespiratoryRate, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_respiratory_rate_to_json(resource),
    resources.RtObservation,
    resources.us_core_respiratory_rate_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_respiratory_rate_delete(
  resource: resources.UsCoreRespiratoryRate,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_servicerequest_create(
  resource: resources.UsCoreServicerequest,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreServicerequest, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_servicerequest_to_json(resource),
    resources.RtServicerequest,
    resources.us_core_servicerequest_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_servicerequest_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreServicerequest, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtServicerequest,
    resources.us_core_servicerequest_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_servicerequest_update(
  resource: resources.UsCoreServicerequest,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreServicerequest, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_servicerequest_to_json(resource),
    resources.RtServicerequest,
    resources.us_core_servicerequest_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_servicerequest_delete(
  resource: resources.UsCoreServicerequest,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtServicerequest, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_simple_observation_create(
  resource: resources.UsCoreSimpleObservation,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreSimpleObservation, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_simple_observation_to_json(resource),
    resources.RtObservation,
    resources.us_core_simple_observation_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_simple_observation_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreSimpleObservation, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_simple_observation_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_simple_observation_update(
  resource: resources.UsCoreSimpleObservation,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreSimpleObservation, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_simple_observation_to_json(resource),
    resources.RtObservation,
    resources.us_core_simple_observation_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_simple_observation_delete(
  resource: resources.UsCoreSimpleObservation,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_smokingstatus_create(
  resource: resources.UsCoreSmokingstatus,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreSmokingstatus, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_smokingstatus_to_json(resource),
    resources.RtObservation,
    resources.us_core_smokingstatus_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_smokingstatus_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreSmokingstatus, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_smokingstatus_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_smokingstatus_update(
  resource: resources.UsCoreSmokingstatus,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreSmokingstatus, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_smokingstatus_to_json(resource),
    resources.RtObservation,
    resources.us_core_smokingstatus_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_smokingstatus_delete(
  resource: resources.UsCoreSmokingstatus,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_specimen_create(
  resource: resources.UsCoreSpecimen,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreSpecimen, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_specimen_to_json(resource),
    resources.RtSpecimen,
    resources.us_core_specimen_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_specimen_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreSpecimen, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtSpecimen,
    resources.us_core_specimen_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_specimen_update(
  resource: resources.UsCoreSpecimen,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreSpecimen, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_specimen_to_json(resource),
    resources.RtSpecimen,
    resources.us_core_specimen_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_specimen_delete(
  resource: resources.UsCoreSpecimen,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtSpecimen, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_treatment_intervention_preference_create(
  resource: resources.UsCoreTreatmentInterventionPreference,
  client: FhirClient,
  handle_response: fn(
    Result(resources.UsCoreTreatmentInterventionPreference, Err),
  ) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_treatment_intervention_preference_to_json(resource),
    resources.RtObservation,
    resources.us_core_treatment_intervention_preference_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_treatment_intervention_preference_read(
  id: String,
  client: FhirClient,
  handle_response: fn(
    Result(resources.UsCoreTreatmentInterventionPreference, Err),
  ) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_treatment_intervention_preference_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_treatment_intervention_preference_update(
  resource: resources.UsCoreTreatmentInterventionPreference,
  client: FhirClient,
  handle_response: fn(
    Result(resources.UsCoreTreatmentInterventionPreference, Err),
  ) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_treatment_intervention_preference_to_json(resource),
    resources.RtObservation,
    resources.us_core_treatment_intervention_preference_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_treatment_intervention_preference_delete(
  resource: resources.UsCoreTreatmentInterventionPreference,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn us_core_vital_signs_create(
  resource: resources.UsCoreVitalSigns,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreVitalSigns, Err)) -> a,
) -> Effect(a) {
  any_create(
    resources.us_core_vital_signs_to_json(resource),
    resources.RtObservation,
    resources.us_core_vital_signs_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_vital_signs_read(
  id: String,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreVitalSigns, Err)) -> a,
) -> Effect(a) {
  any_read(
    id,
    resources.RtObservation,
    resources.us_core_vital_signs_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_vital_signs_update(
  resource: resources.UsCoreVitalSigns,
  client: FhirClient,
  handle_response: fn(Result(resources.UsCoreVitalSigns, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  any_update(
    resource.id,
    resources.us_core_vital_signs_to_json(resource),
    resources.RtObservation,
    resources.us_core_vital_signs_decoder(),
    client,
    handle_response,
  )
}

pub fn us_core_vital_signs_delete(
  resource: resources.UsCoreVitalSigns,
  client: FhirClient,
  handle_response: fn(Result(sansio.OperationoutcomeOrHTTP, Err)) -> a,
) -> Result(Effect(a), ErrNoId) {
  case resource.id {
    Some(id) ->
      Ok(any_delete(id, resources.RtObservation, client, handle_response))
    None -> Error(ErrNoId)
  }
}

pub fn bundle_search_bundled(
  sp: search_params.Bundle,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("composition", sp.composition),
    #("type", sp.type_),
    #("message", sp.message),
    #("timestamp", sp.timestamp),
  ])
  |> search_any(resources.RtBundle, client, handle_response)
}

pub fn bundle_search(
  sp: search_params.Bundle,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Bundle), Err)) -> msg,
) -> Effect(msg) {
  bundle_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.bundle)
      Error(error) -> Error(error)
    })
  })
}

pub fn endpoint_search_bundled(
  sp: search_params.Endpoint,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("payload-type", sp.payload_type),
    #("identifier", sp.identifier),
    #("organization", sp.organization),
    #("connection-type", sp.connection_type),
    #("name", sp.name),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEndpoint, client, handle_response)
}

pub fn endpoint_search(
  sp: search_params.Endpoint,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Endpoint), Err)) -> msg,
) -> Effect(msg) {
  endpoint_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.endpoint)
      Error(error) -> Error(error)
    })
  })
}

pub fn operationoutcome_search_bundled(
  _sp: search_params.Operationoutcome,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([])
  |> search_any(resources.RtOperationoutcome, client, handle_response)
}

pub fn operationoutcome_search(
  sp: search_params.Operationoutcome,
  client: FhirClient,
  handle_response: fn(Result(List(resources.Operationoutcome), Err)) -> msg,
) -> Effect(msg) {
  operationoutcome_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.operationoutcome)
      Error(error) -> Error(error)
    })
  })
}

pub fn head_occipital_frontal_circumference_percentile_search_bundled(
  sp: search_params.HeadOccipitalFrontalCircumferencePercentile,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn head_occipital_frontal_circumference_percentile_search(
  sp: search_params.HeadOccipitalFrontalCircumferencePercentile,
  client: FhirClient,
  handle_response: fn(
    Result(List(resources.HeadOccipitalFrontalCircumferencePercentile), Err),
  ) -> msg,
) -> Effect(msg) {
  head_occipital_frontal_circumference_percentile_search_bundled(
    sp,
    client,
    fn(resp) {
      handle_response(case resp {
        Ok(bundle) ->
          Ok(
            { bundle |> sansio.bundle_to_groupedresources }.head_occipital_frontal_circumference_percentile,
          )
        Error(error) -> Error(error)
      })
    },
  )
}

pub fn pediatric_bmi_for_age_search_bundled(
  sp: search_params.PediatricBmiForAge,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn pediatric_bmi_for_age_search(
  sp: search_params.PediatricBmiForAge,
  client: FhirClient,
  handle_response: fn(Result(List(resources.PediatricBmiForAge), Err)) -> msg,
) -> Effect(msg) {
  pediatric_bmi_for_age_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.pediatric_bmi_for_age,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn pediatric_weight_for_height_search_bundled(
  sp: search_params.PediatricWeightForHeight,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn pediatric_weight_for_height_search(
  sp: search_params.PediatricWeightForHeight,
  client: FhirClient,
  handle_response: fn(Result(List(resources.PediatricWeightForHeight), Err)) ->
    msg,
) -> Effect(msg) {
  pediatric_weight_for_height_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.pediatric_weight_for_height,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_allergyintolerance_search_bundled(
  sp: search_params.UsCoreAllergyintolerance,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("clinical-status", sp.clinical_status),
    #("patient", sp.patient),
  ])
  |> search_any(resources.RtAllergyintolerance, client, handle_response)
}

pub fn us_core_allergyintolerance_search(
  sp: search_params.UsCoreAllergyintolerance,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreAllergyintolerance), Err)) ->
    msg,
) -> Effect(msg) {
  us_core_allergyintolerance_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_allergyintolerance,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_average_blood_pressure_search_bundled(
  sp: search_params.UsCoreAverageBloodPressure,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_average_blood_pressure_search(
  sp: search_params.UsCoreAverageBloodPressure,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreAverageBloodPressure), Err)) ->
    msg,
) -> Effect(msg) {
  us_core_average_blood_pressure_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_average_blood_pressure,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_blood_pressure_search_bundled(
  sp: search_params.UsCoreBloodPressure,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_blood_pressure_search(
  sp: search_params.UsCoreBloodPressure,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreBloodPressure), Err)) -> msg,
) -> Effect(msg) {
  us_core_blood_pressure_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_blood_pressure,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_bmi_search_bundled(
  sp: search_params.UsCoreBmi,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_bmi_search(
  sp: search_params.UsCoreBmi,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreBmi), Err)) -> msg,
) -> Effect(msg) {
  us_core_bmi_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_bmi)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_body_height_search_bundled(
  sp: search_params.UsCoreBodyHeight,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_body_height_search(
  sp: search_params.UsCoreBodyHeight,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreBodyHeight), Err)) -> msg,
) -> Effect(msg) {
  us_core_body_height_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_body_height)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_body_temperature_search_bundled(
  sp: search_params.UsCoreBodyTemperature,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_body_temperature_search(
  sp: search_params.UsCoreBodyTemperature,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreBodyTemperature), Err)) -> msg,
) -> Effect(msg) {
  us_core_body_temperature_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_body_temperature,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_body_weight_search_bundled(
  sp: search_params.UsCoreBodyWeight,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_body_weight_search(
  sp: search_params.UsCoreBodyWeight,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreBodyWeight), Err)) -> msg,
) -> Effect(msg) {
  us_core_body_weight_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_body_weight)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_care_experience_preference_search_bundled(
  sp: search_params.UsCoreCareExperiencePreference,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_care_experience_preference_search(
  sp: search_params.UsCoreCareExperiencePreference,
  client: FhirClient,
  handle_response: fn(
    Result(List(resources.UsCoreCareExperiencePreference), Err),
  ) -> msg,
) -> Effect(msg) {
  us_core_care_experience_preference_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_care_experience_preference,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_careplan_search_bundled(
  sp: search_params.UsCoreCareplan,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("date", sp.date),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCareplan, client, handle_response)
}

pub fn us_core_careplan_search(
  sp: search_params.UsCoreCareplan,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreCareplan), Err)) -> msg,
) -> Effect(msg) {
  us_core_careplan_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_careplan)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_careteam_search_bundled(
  sp: search_params.UsCoreCareteam,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("patient", sp.patient),
    #("role", sp.role),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCareteam, client, handle_response)
}

pub fn us_core_careteam_search(
  sp: search_params.UsCoreCareteam,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreCareteam), Err)) -> msg,
) -> Effect(msg) {
  us_core_careteam_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_careteam)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_condition_encounter_diagnosis_search_bundled(
  sp: search_params.UsCoreConditionEncounterDiagnosis,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
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
  |> search_any(resources.RtCondition, client, handle_response)
}

pub fn us_core_condition_encounter_diagnosis_search(
  sp: search_params.UsCoreConditionEncounterDiagnosis,
  client: FhirClient,
  handle_response: fn(
    Result(List(resources.UsCoreConditionEncounterDiagnosis), Err),
  ) -> msg,
) -> Effect(msg) {
  us_core_condition_encounter_diagnosis_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_condition_encounter_diagnosis,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_condition_problems_health_concerns_search_bundled(
  sp: search_params.UsCoreConditionProblemsHealthConcerns,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
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
  |> search_any(resources.RtCondition, client, handle_response)
}

pub fn us_core_condition_problems_health_concerns_search(
  sp: search_params.UsCoreConditionProblemsHealthConcerns,
  client: FhirClient,
  handle_response: fn(
    Result(List(resources.UsCoreConditionProblemsHealthConcerns), Err),
  ) -> msg,
) -> Effect(msg) {
  us_core_condition_problems_health_concerns_search_bundled(
    sp,
    client,
    fn(resp) {
      handle_response(case resp {
        Ok(bundle) ->
          Ok(
            { bundle |> sansio.bundle_to_groupedresources }.us_core_condition_problems_health_concerns,
          )
        Error(error) -> Error(error)
      })
    },
  )
}

pub fn us_core_coverage_search_bundled(
  sp: search_params.UsCoreCoverage,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("patient", sp.patient),
  ])
  |> search_any(resources.RtCoverage, client, handle_response)
}

pub fn us_core_coverage_search(
  sp: search_params.UsCoreCoverage,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreCoverage), Err)) -> msg,
) -> Effect(msg) {
  us_core_coverage_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_coverage)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_diagnosticreport_lab_search_bundled(
  sp: search_params.UsCoreDiagnosticreportLab,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDiagnosticreport, client, handle_response)
}

pub fn us_core_diagnosticreport_lab_search(
  sp: search_params.UsCoreDiagnosticreportLab,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreDiagnosticreportLab), Err)) ->
    msg,
) -> Effect(msg) {
  us_core_diagnosticreport_lab_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_diagnosticreport_lab,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_diagnosticreport_note_search_bundled(
  sp: search_params.UsCoreDiagnosticreportNote,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDiagnosticreport, client, handle_response)
}

pub fn us_core_diagnosticreport_note_search(
  sp: search_params.UsCoreDiagnosticreportNote,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreDiagnosticreportNote), Err)) ->
    msg,
) -> Effect(msg) {
  us_core_diagnosticreport_note_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_diagnosticreport_note,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_documentreference_search_bundled(
  sp: search_params.UsCoreDocumentreference,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("_id", sp.id),
    #("category", sp.category),
    #("date", sp.date),
    #("patient", sp.patient),
    #("period", sp.period),
    #("status", sp.status),
    #("type", sp.type_),
  ])
  |> search_any(resources.RtDocumentreference, client, handle_response)
}

pub fn us_core_documentreference_search(
  sp: search_params.UsCoreDocumentreference,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreDocumentreference), Err)) ->
    msg,
) -> Effect(msg) {
  us_core_documentreference_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_documentreference,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_encounter_search_bundled(
  sp: search_params.UsCoreEncounter,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
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
  |> search_any(resources.RtEncounter, client, handle_response)
}

pub fn us_core_encounter_search(
  sp: search_params.UsCoreEncounter,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreEncounter), Err)) -> msg,
) -> Effect(msg) {
  us_core_encounter_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_encounter)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_goal_search_bundled(
  sp: search_params.UsCoreGoal,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("description", sp.description),
    #("lifecycle-status", sp.lifecycle_status),
    #("patient", sp.patient),
    #("target-date", sp.target_date),
  ])
  |> search_any(resources.RtGoal, client, handle_response)
}

pub fn us_core_goal_search(
  sp: search_params.UsCoreGoal,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreGoal), Err)) -> msg,
) -> Effect(msg) {
  us_core_goal_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_goal)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_head_circumference_search_bundled(
  sp: search_params.UsCoreHeadCircumference,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_head_circumference_search(
  sp: search_params.UsCoreHeadCircumference,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreHeadCircumference), Err)) ->
    msg,
) -> Effect(msg) {
  us_core_head_circumference_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_head_circumference,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_heart_rate_search_bundled(
  sp: search_params.UsCoreHeartRate,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_heart_rate_search(
  sp: search_params.UsCoreHeartRate,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreHeartRate), Err)) -> msg,
) -> Effect(msg) {
  us_core_heart_rate_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_heart_rate)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_immunization_search_bundled(
  sp: search_params.UsCoreImmunization,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("date", sp.date),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtImmunization, client, handle_response)
}

pub fn us_core_immunization_search(
  sp: search_params.UsCoreImmunization,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreImmunization), Err)) -> msg,
) -> Effect(msg) {
  us_core_immunization_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_immunization)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_implantable_device_search_bundled(
  sp: search_params.UsCoreImplantableDevice,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("patient", sp.patient),
    #("status", sp.status),
    #("type", sp.type_),
  ])
  |> search_any(resources.RtDevice, client, handle_response)
}

pub fn us_core_implantable_device_search(
  sp: search_params.UsCoreImplantableDevice,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreImplantableDevice), Err)) ->
    msg,
) -> Effect(msg) {
  us_core_implantable_device_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_implantable_device,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_location_search_bundled(
  sp: search_params.UsCoreLocation,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("address", sp.address),
    #("address-city", sp.address_city),
    #("address-postalcode", sp.address_postalcode),
    #("address-state", sp.address_state),
    #("name", sp.name),
  ])
  |> search_any(resources.RtLocation, client, handle_response)
}

pub fn us_core_location_search(
  sp: search_params.UsCoreLocation,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreLocation), Err)) -> msg,
) -> Effect(msg) {
  us_core_location_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_location)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_medication_search_bundled(
  _sp: search_params.UsCoreMedication,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([])
  |> search_any(resources.RtMedication, client, handle_response)
}

pub fn us_core_medication_search(
  sp: search_params.UsCoreMedication,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreMedication), Err)) -> msg,
) -> Effect(msg) {
  us_core_medication_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_medication)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_medicationdispense_search_bundled(
  sp: search_params.UsCoreMedicationdispense,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("patient", sp.patient),
    #("status", sp.status),
    #("type", sp.type_),
  ])
  |> search_any(resources.RtMedicationdispense, client, handle_response)
}

pub fn us_core_medicationdispense_search(
  sp: search_params.UsCoreMedicationdispense,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreMedicationdispense), Err)) ->
    msg,
) -> Effect(msg) {
  us_core_medicationdispense_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_medicationdispense,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_medicationrequest_search_bundled(
  sp: search_params.UsCoreMedicationrequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("authoredon", sp.authoredon),
    #("encounter", sp.encounter),
    #("intent", sp.intent),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicationrequest, client, handle_response)
}

pub fn us_core_medicationrequest_search(
  sp: search_params.UsCoreMedicationrequest,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreMedicationrequest), Err)) ->
    msg,
) -> Effect(msg) {
  us_core_medicationrequest_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_medicationrequest,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_observation_clinical_result_search_bundled(
  sp: search_params.UsCoreObservationClinicalResult,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_observation_clinical_result_search(
  sp: search_params.UsCoreObservationClinicalResult,
  client: FhirClient,
  handle_response: fn(
    Result(List(resources.UsCoreObservationClinicalResult), Err),
  ) -> msg,
) -> Effect(msg) {
  us_core_observation_clinical_result_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_clinical_result,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_observation_lab_search_bundled(
  sp: search_params.UsCoreObservationLab,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_observation_lab_search(
  sp: search_params.UsCoreObservationLab,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreObservationLab), Err)) -> msg,
) -> Effect(msg) {
  us_core_observation_lab_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_lab,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_observation_occupation_search_bundled(
  sp: search_params.UsCoreObservationOccupation,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_observation_occupation_search(
  sp: search_params.UsCoreObservationOccupation,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreObservationOccupation), Err)) ->
    msg,
) -> Effect(msg) {
  us_core_observation_occupation_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_occupation,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_observation_pregnancyintent_search_bundled(
  sp: search_params.UsCoreObservationPregnancyintent,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_observation_pregnancyintent_search(
  sp: search_params.UsCoreObservationPregnancyintent,
  client: FhirClient,
  handle_response: fn(
    Result(List(resources.UsCoreObservationPregnancyintent), Err),
  ) -> msg,
) -> Effect(msg) {
  us_core_observation_pregnancyintent_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_pregnancyintent,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_observation_pregnancystatus_search_bundled(
  sp: search_params.UsCoreObservationPregnancystatus,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_observation_pregnancystatus_search(
  sp: search_params.UsCoreObservationPregnancystatus,
  client: FhirClient,
  handle_response: fn(
    Result(List(resources.UsCoreObservationPregnancystatus), Err),
  ) -> msg,
) -> Effect(msg) {
  us_core_observation_pregnancystatus_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_pregnancystatus,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_observation_screening_assessment_search_bundled(
  sp: search_params.UsCoreObservationScreeningAssessment,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_observation_screening_assessment_search(
  sp: search_params.UsCoreObservationScreeningAssessment,
  client: FhirClient,
  handle_response: fn(
    Result(List(resources.UsCoreObservationScreeningAssessment), Err),
  ) -> msg,
) -> Effect(msg) {
  us_core_observation_screening_assessment_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_screening_assessment,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_observation_sexual_orientation_search_bundled(
  sp: search_params.UsCoreObservationSexualOrientation,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_observation_sexual_orientation_search(
  sp: search_params.UsCoreObservationSexualOrientation,
  client: FhirClient,
  handle_response: fn(
    Result(List(resources.UsCoreObservationSexualOrientation), Err),
  ) -> msg,
) -> Effect(msg) {
  us_core_observation_sexual_orientation_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_observation_sexual_orientation,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_organization_search_bundled(
  sp: search_params.UsCoreOrganization,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("address", sp.address),
    #("name", sp.name),
  ])
  |> search_any(resources.RtOrganization, client, handle_response)
}

pub fn us_core_organization_search(
  sp: search_params.UsCoreOrganization,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreOrganization), Err)) -> msg,
) -> Effect(msg) {
  us_core_organization_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_organization)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_patient_search_bundled(
  sp: search_params.UsCorePatient,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
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
  |> search_any(resources.RtPatient, client, handle_response)
}

pub fn us_core_patient_search(
  sp: search_params.UsCorePatient,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCorePatient), Err)) -> msg,
) -> Effect(msg) {
  us_core_patient_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_patient)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_practitioner_search_bundled(
  sp: search_params.UsCorePractitioner,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("_id", sp.id),
    #("identifier", sp.identifier),
    #("name", sp.name),
  ])
  |> search_any(resources.RtPractitioner, client, handle_response)
}

pub fn us_core_practitioner_search(
  sp: search_params.UsCorePractitioner,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCorePractitioner), Err)) -> msg,
) -> Effect(msg) {
  us_core_practitioner_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_practitioner)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_practitionerrole_search_bundled(
  sp: search_params.UsCorePractitionerrole,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("practitioner", sp.practitioner),
    #("specialty", sp.specialty),
  ])
  |> search_any(resources.RtPractitionerrole, client, handle_response)
}

pub fn us_core_practitionerrole_search(
  sp: search_params.UsCorePractitionerrole,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCorePractitionerrole), Err)) ->
    msg,
) -> Effect(msg) {
  us_core_practitionerrole_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_practitionerrole,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_procedure_search_bundled(
  sp: search_params.UsCoreProcedure,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("code", sp.code),
    #("date", sp.date),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtProcedure, client, handle_response)
}

pub fn us_core_procedure_search(
  sp: search_params.UsCoreProcedure,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreProcedure), Err)) -> msg,
) -> Effect(msg) {
  us_core_procedure_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_procedure)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_provenance_search_bundled(
  _sp: search_params.UsCoreProvenance,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([])
  |> search_any(resources.RtProvenance, client, handle_response)
}

pub fn us_core_provenance_search(
  sp: search_params.UsCoreProvenance,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreProvenance), Err)) -> msg,
) -> Effect(msg) {
  us_core_provenance_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_provenance)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_pulse_oximetry_search_bundled(
  sp: search_params.UsCorePulseOximetry,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_pulse_oximetry_search(
  sp: search_params.UsCorePulseOximetry,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCorePulseOximetry), Err)) -> msg,
) -> Effect(msg) {
  us_core_pulse_oximetry_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_pulse_oximetry,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_questionnaireresponse_search_bundled(
  sp: search_params.UsCoreQuestionnaireresponse,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("_id", sp.id),
    #("authored", sp.authored),
    #("patient", sp.patient),
    #("questionnaire", sp.questionnaire),
    #("status", sp.status),
  ])
  |> search_any(resources.RtQuestionnaireresponse, client, handle_response)
}

pub fn us_core_questionnaireresponse_search(
  sp: search_params.UsCoreQuestionnaireresponse,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreQuestionnaireresponse), Err)) ->
    msg,
) -> Effect(msg) {
  us_core_questionnaireresponse_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_questionnaireresponse,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_relatedperson_search_bundled(
  sp: search_params.UsCoreRelatedperson,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("_id", sp.id),
    #("name", sp.name),
    #("patient", sp.patient),
  ])
  |> search_any(resources.RtRelatedperson, client, handle_response)
}

pub fn us_core_relatedperson_search(
  sp: search_params.UsCoreRelatedperson,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreRelatedperson), Err)) -> msg,
) -> Effect(msg) {
  us_core_relatedperson_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_relatedperson,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_respiratory_rate_search_bundled(
  sp: search_params.UsCoreRespiratoryRate,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_respiratory_rate_search(
  sp: search_params.UsCoreRespiratoryRate,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreRespiratoryRate), Err)) -> msg,
) -> Effect(msg) {
  us_core_respiratory_rate_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_respiratory_rate,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_servicerequest_search_bundled(
  sp: search_params.UsCoreServicerequest,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("_id", sp.id),
    #("authored", sp.authored),
    #("category", sp.category),
    #("code", sp.code),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtServicerequest, client, handle_response)
}

pub fn us_core_servicerequest_search(
  sp: search_params.UsCoreServicerequest,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreServicerequest), Err)) -> msg,
) -> Effect(msg) {
  us_core_servicerequest_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_servicerequest,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_simple_observation_search_bundled(
  sp: search_params.UsCoreSimpleObservation,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_simple_observation_search(
  sp: search_params.UsCoreSimpleObservation,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreSimpleObservation), Err)) ->
    msg,
) -> Effect(msg) {
  us_core_simple_observation_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_simple_observation,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_smokingstatus_search_bundled(
  sp: search_params.UsCoreSmokingstatus,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_smokingstatus_search(
  sp: search_params.UsCoreSmokingstatus,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreSmokingstatus), Err)) -> msg,
) -> Effect(msg) {
  us_core_smokingstatus_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_smokingstatus,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_specimen_search_bundled(
  sp: search_params.UsCoreSpecimen,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("_id", sp.id),
    #("patient", sp.patient),
  ])
  |> search_any(resources.RtSpecimen, client, handle_response)
}

pub fn us_core_specimen_search(
  sp: search_params.UsCoreSpecimen,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreSpecimen), Err)) -> msg,
) -> Effect(msg) {
  us_core_specimen_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_specimen)
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_treatment_intervention_preference_search_bundled(
  sp: search_params.UsCoreTreatmentInterventionPreference,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_treatment_intervention_preference_search(
  sp: search_params.UsCoreTreatmentInterventionPreference,
  client: FhirClient,
  handle_response: fn(
    Result(List(resources.UsCoreTreatmentInterventionPreference), Err),
  ) -> msg,
) -> Effect(msg) {
  us_core_treatment_intervention_preference_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok(
          { bundle |> sansio.bundle_to_groupedresources }.us_core_treatment_intervention_preference,
        )
      Error(error) -> Error(error)
    })
  })
}

pub fn us_core_vital_signs_search_bundled(
  sp: search_params.UsCoreVitalSigns,
  client: FhirClient,
  handle_response: fn(Result(resources.Bundle, Err)) -> msg,
) -> Effect(msg) {
  search_params.to_string([
    #("category", sp.category),
    #("code", sp.code),
    #("date", sp.date),
    #("_lastUpdated", sp.lastupdated),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client, handle_response)
}

pub fn us_core_vital_signs_search(
  sp: search_params.UsCoreVitalSigns,
  client: FhirClient,
  handle_response: fn(Result(List(resources.UsCoreVitalSigns), Err)) -> msg,
) -> Effect(msg) {
  us_core_vital_signs_search_bundled(sp, client, fn(resp) {
    handle_response(case resp {
      Ok(bundle) ->
        Ok({ bundle |> sansio.bundle_to_groupedresources }.us_core_vital_signs)
      Error(error) -> Error(error)
    })
  })
}
