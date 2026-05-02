/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
package org.apache.polaris.extension.storage.oci;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.apache.avro.Schema;
import org.apache.avro.SchemaBuilder;
import org.apache.avro.file.CodecFactory;
import org.apache.avro.file.DataFileStream;
import org.apache.avro.file.DataFileWriter;
import org.apache.avro.generic.GenericData;
import org.apache.avro.generic.GenericDatumReader;
import org.apache.avro.generic.GenericDatumWriter;
import org.apache.avro.generic.GenericRecord;
import org.junit.jupiter.api.Test;

class GenericAvroRewriterTest {

  private final GenericAvroRewriter rewriter =
      new GenericAvroRewriter(new OciUriRewriter("axydmvgg0v5v", "us-sanjose-1"));

  /**
   * Iceberg manifest-list-shape avro: each record references a manifest file via its path field
   * and embeds a nested record. Round-trip must rewrite both the top-level path and any nested
   * URI strings.
   */
  @Test
  void rewritesIcebergLikeManifestListAvro() throws Exception {
    Schema partitionSchema =
        SchemaBuilder.record("PartitionFieldSummary")
            .fields()
            .requiredBoolean("contains_null")
            .endRecord();

    Schema manifestFileSchema =
        SchemaBuilder.record("ManifestFile")
            .fields()
            .requiredString("manifest_path")
            .requiredLong("manifest_length")
            .name("partitions")
            .type()
            .array()
            .items(partitionSchema)
            .noDefault()
            .endRecord();

    GenericData.Record entry1 = new GenericData.Record(manifestFileSchema);
    entry1.put("manifest_path", "s3://polaris-iceberg/demo/users/metadata/m1.avro");
    entry1.put("manifest_length", 12345L);
    entry1.put("partitions", new ArrayList<>());

    GenericData.Record entry2 = new GenericData.Record(manifestFileSchema);
    entry2.put("manifest_path", "s3a://polaris-iceberg/demo/orders/metadata/m2.avro");
    entry2.put("manifest_length", 67890L);
    entry2.put("partitions", new ArrayList<>());

    byte[] input = writeAvro(manifestFileSchema, List.of(entry1, entry2));
    byte[] output = rewriter.rewrite(input);

    List<GenericRecord> roundTripped = readAvro(output);
    assertThat(roundTripped).hasSize(2);
    assertThat(roundTripped.get(0).get("manifest_path").toString())
        .isEqualTo(
            "https://objectstorage.us-sanjose-1.oraclecloud.com"
                + "/n/axydmvgg0v5v/b/polaris-iceberg/o/demo/users/metadata/m1.avro");
    assertThat(roundTripped.get(1).get("manifest_path").toString())
        .isEqualTo(
            "https://objectstorage.us-sanjose-1.oraclecloud.com"
                + "/n/axydmvgg0v5v/b/polaris-iceberg/o/demo/orders/metadata/m2.avro");
    // Non-URI fields preserved
    assertThat(roundTripped.get(0).get("manifest_length")).isEqualTo(12345L);
    assertThat(roundTripped.get(1).get("manifest_length")).isEqualTo(67890L);
  }

  /**
   * Iceberg manifest-shape avro: top-level fields plus a nested {@code data_file} record whose
   * {@code file_path} is the data file URI. Round-trip must descend into the nested record.
   */
  @Test
  void rewritesNestedDataFilePath() throws Exception {
    Schema dataFileSchema =
        SchemaBuilder.record("DataFile")
            .fields()
            .requiredString("file_path")
            .requiredString("file_format")
            .name("metrics")
            .type()
            .map()
            .values()
            .stringType()
            .noDefault()
            .endRecord();

    Schema manifestEntrySchema =
        SchemaBuilder.record("ManifestEntry")
            .fields()
            .requiredInt("status")
            .name("data_file")
            .type(dataFileSchema)
            .noDefault()
            .endRecord();

    Map<CharSequence, CharSequence> metrics = new HashMap<>();
    metrics.put("aux", "s3://polaris-iceberg/demo/users/data/0.parquet");
    metrics.put("plain", "literal-no-rewrite");

    GenericData.Record dataFile = new GenericData.Record(dataFileSchema);
    dataFile.put("file_path", "s3://polaris-iceberg/demo/users/data/0.parquet");
    dataFile.put("file_format", "PARQUET");
    dataFile.put("metrics", metrics);

    GenericData.Record entry = new GenericData.Record(manifestEntrySchema);
    entry.put("status", 1);
    entry.put("data_file", dataFile);

    byte[] input = writeAvro(manifestEntrySchema, List.of(entry));
    byte[] output = rewriter.rewrite(input);

    List<GenericRecord> roundTripped = readAvro(output);
    assertThat(roundTripped).hasSize(1);
    GenericRecord rewrittenDataFile = (GenericRecord) roundTripped.get(0).get("data_file");
    String expectedDataPath =
        "https://objectstorage.us-sanjose-1.oraclecloud.com"
            + "/n/axydmvgg0v5v/b/polaris-iceberg/o/demo/users/data/0.parquet";
    assertThat(rewrittenDataFile.get("file_path").toString()).isEqualTo(expectedDataPath);
    @SuppressWarnings("unchecked")
    Map<CharSequence, CharSequence> rewrittenMetrics =
        (Map<CharSequence, CharSequence>) rewrittenDataFile.get("metrics");
    assertThat(rewrittenMetrics.get(new org.apache.avro.util.Utf8("aux")).toString())
        .isEqualTo(expectedDataPath);
    assertThat(rewrittenMetrics.get(new org.apache.avro.util.Utf8("plain")).toString())
        .isEqualTo("literal-no-rewrite");
  }

  @Test
  void schemaAndCodecPreservedSoIcebergReadersStayCompatible() throws Exception {
    Schema schema =
        SchemaBuilder.record("Probe")
            .fields()
            .requiredString("uri")
            .endRecord();
    GenericData.Record r = new GenericData.Record(schema);
    r.put("uri", "s3://b/k");

    byte[] output = rewriter.rewrite(writeAvro(schema, List.of(r)));

    try (DataFileStream<GenericRecord> stream =
        new DataFileStream<>(new ByteArrayInputStream(output), new GenericDatumReader<>())) {
      assertThat(stream.getSchema().getFullName()).isEqualTo("Probe");
    }
  }

  private static byte[] writeAvro(Schema schema, List<GenericData.Record> records)
      throws Exception {
    ByteArrayOutputStream bos = new ByteArrayOutputStream();
    try (DataFileWriter<GenericRecord> writer =
        new DataFileWriter<>(new GenericDatumWriter<>(schema))) {
      writer.setCodec(CodecFactory.nullCodec());
      writer.create(schema, bos);
      for (GenericData.Record r : records) {
        writer.append(r);
      }
    }
    return bos.toByteArray();
  }

  private static List<GenericRecord> readAvro(byte[] bytes) throws Exception {
    List<GenericRecord> result = new ArrayList<>();
    try (DataFileStream<GenericRecord> stream =
        new DataFileStream<>(new ByteArrayInputStream(bytes), new GenericDatumReader<>())) {
      for (GenericRecord r : stream) {
        result.add(r);
      }
    }
    return result;
  }
}
