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

import jakarta.annotation.Nonnull;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.apache.avro.Schema;
import org.apache.avro.file.DataFileStream;
import org.apache.avro.file.DataFileWriter;
import org.apache.avro.generic.GenericDatumReader;
import org.apache.avro.generic.GenericDatumWriter;
import org.apache.avro.generic.GenericRecord;
import org.apache.avro.util.Utf8;

/**
 * Round-trips an avro container file, applying {@link OciUriRewriter} to every string field
 * recursively. Schema-agnostic: works for iceberg manifest-list avros, iceberg manifest avros,
 * and any other avro container we might want to retarget.
 *
 * <p>The output file uses the input file's exact schema and codec, so an iceberg reader can
 * consume the rewritten file as if it were the original.
 */
public final class GenericAvroRewriter {

  private final OciUriRewriter uriRewriter;

  public GenericAvroRewriter(@Nonnull OciUriRewriter uriRewriter) {
    this.uriRewriter = uriRewriter;
  }

  /**
   * Reads an avro container from {@code input}, rewrites all matching URI strings in every
   * record, and returns the new container as bytes.
   */
  public byte[] rewrite(@Nonnull byte[] input) throws IOException {
    try (ByteArrayInputStream bis = new ByteArrayInputStream(input);
        DataFileStream<GenericRecord> reader =
            new DataFileStream<>(bis, new GenericDatumReader<>())) {
      Schema schema = reader.getSchema();
      ByteArrayOutputStream bos = new ByteArrayOutputStream(input.length);
      try (DataFileWriter<GenericRecord> writer =
          new DataFileWriter<>(new GenericDatumWriter<>(schema))) {
        // Preserve compression codec + every metadata key/value (iceberg adds
        // its own entries the reader on the other side may rely on).
        for (String key : reader.getMetaKeys()) {
          if (!key.startsWith("avro.")) {
            writer.setMeta(key, reader.getMeta(key));
          }
        }
        writer.create(schema, bos);
        for (GenericRecord record : reader) {
          rewriteRecord(record, schema);
          writer.append(record);
        }
      }
      return bos.toByteArray();
    }
  }

  /**
   * Recursively walks {@code record} and rewrites every string field whose value matches the
   * rewriter's pattern. Mutates the record in place.
   */
  private void rewriteRecord(GenericRecord record, Schema schema) {
    if (record == null) {
      return;
    }
    for (Schema.Field field : schema.getFields()) {
      Object value = record.get(field.pos());
      Object rewritten = rewriteValue(value, field.schema());
      if (rewritten != value) {
        record.put(field.pos(), rewritten);
      }
    }
  }

  /**
   * Returns a rewritten replacement for {@code value} (or the original if no rewrite applies).
   * Handles strings (applies the rewriter), records (recurses), arrays (per-element), maps
   * (per-value), and unions (resolves to the actual branch).
   */
  private Object rewriteValue(Object value, Schema schema) {
    if (value == null) {
      return null;
    }
    Schema effective = unwrapUnion(schema, value);
    switch (effective.getType()) {
      case STRING:
        String stringValue = value instanceof Utf8 ? value.toString() : (String) value;
        if (!OciUriRewriter.isRewritable(stringValue)) {
          return value;
        }
        // Avro reads strings as Utf8; preserve that representation so writers
        // don't redo the encoding.
        return value instanceof Utf8
            ? new Utf8(uriRewriter.rewrite(stringValue))
            : uriRewriter.rewrite(stringValue);
      case RECORD:
        rewriteRecord((GenericRecord) value, effective);
        return value;
      case ARRAY:
        @SuppressWarnings("unchecked")
        List<Object> list = (List<Object>) value;
        Schema elementSchema = effective.getElementType();
        for (int i = 0; i < list.size(); i++) {
          Object replaced = rewriteValue(list.get(i), elementSchema);
          if (replaced != list.get(i)) {
            list.set(i, replaced);
          }
        }
        return value;
      case MAP:
        @SuppressWarnings("unchecked")
        Map<CharSequence, Object> map = (Map<CharSequence, Object>) value;
        Schema valueSchema = effective.getValueType();
        Map<CharSequence, Object> updates = new HashMap<>();
        for (Map.Entry<CharSequence, Object> entry : map.entrySet()) {
          Object replaced = rewriteValue(entry.getValue(), valueSchema);
          if (replaced != entry.getValue()) {
            updates.put(entry.getKey(), replaced);
          }
        }
        updates.forEach(map::put);
        return value;
      default:
        // primitives we don't touch (int, long, float, double, boolean, bytes, fixed, enum)
        return value;
    }
  }

  /** If {@code schema} is a union, picks the branch that matches {@code value}. */
  private Schema unwrapUnion(Schema schema, Object value) {
    if (schema.getType() != Schema.Type.UNION) {
      return schema;
    }
    for (Schema branch : schema.getTypes()) {
      if (branch.getType() == Schema.Type.NULL) {
        if (value == null) {
          return branch;
        }
        continue;
      }
      if (matchesType(branch, value)) {
        return branch;
      }
    }
    // Fallback: first non-null branch.
    return schema.getTypes().stream()
        .filter(s -> s.getType() != Schema.Type.NULL)
        .findFirst()
        .orElse(schema);
  }

  private boolean matchesType(Schema schema, Object value) {
    return switch (schema.getType()) {
      case STRING -> value instanceof CharSequence;
      case RECORD -> value instanceof GenericRecord rec
          && schema.getFullName().equals(rec.getSchema().getFullName());
      case ARRAY -> value instanceof List;
      case MAP -> value instanceof Map;
      case INT -> value instanceof Integer;
      case LONG -> value instanceof Long;
      case FLOAT -> value instanceof Float;
      case DOUBLE -> value instanceof Double;
      case BOOLEAN -> value instanceof Boolean;
      case BYTES -> value instanceof java.nio.ByteBuffer || value instanceof byte[];
      case FIXED -> value instanceof org.apache.avro.generic.GenericFixed;
      case ENUM -> value instanceof org.apache.avro.generic.GenericEnumSymbol;
      default -> false;
    };
  }
}
